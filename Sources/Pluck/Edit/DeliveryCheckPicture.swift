import AVFoundation
import Vision

/// The picture checks: every frame's brightness and a 64×36 grey copy of it, so what happens
/// around a cut can be told apart: a transition someone made (dissolve, fade, dip, whip pan,
/// flash, wipe) from a frame left over from an edit or black that shouldn't be there.
extension DeliveryCheck {
    /// Thresholds for the picture, each with why. Brightness is 8-bit luma (16 black … 235 white).
    enum Tune {
        /// A cut: a frame difference this many times the local median (and at least `cutFloor`), as before.
        static let cutFactor = 5.0
        static let cutFloor = 8.0
        /// Frames between two cuts this few: maybe left over (longer is a shot).
        static let strayFrames = 2
        /// 10–90 % luma spread under this: a plain frame of one colour.
        static let plainRange = 24.0
        /// A plain frame this bright is white.
        static let whiteLevel = 200.0
        /// A fade: at least this many frames each a step the same way…
        static let rampFrames = 3
        /// …at least this much brightness change in all…
        static let rampRise = 12.0
        /// …and the last step into black or white no more than this share of it (a big last step is a cut).
        static let rampLastStep = 0.5
        /// A fade longer than this is just the shot getting darker; stop looking.
        static let rampLongest = 3.0
        /// Flash or light leak: a few frames at a cut this much brighter than the shot on their side…
        static let flashRise = 30.0
        /// …and flatter (this share of its contrast or less): light washing the picture out, not a bright shot.
        static let flashContrast = 0.85
        /// Motion blur: sharpness along one direction under this share of the shot's own…
        static let blurShare = 0.5
        /// …and this many times blurrier one way than the other (a whip, not a soft shot).
        static let blurDirection = 1.6
        /// Frames either side of a cut looked at for a whip pan or a flash.
        static let aroundCut = 6
        /// A mix of the frames either side: what's left after the best mix, as a share of how different they are.
        /// Strict for a frame or two between cuts…
        static let blendResidual = 0.15
        /// …looser across a dissolve, where both shots keep moving (measured: 0.2–0.4 on panning shots)…
        static let dissolveResidual = 0.4
        /// …so it also needs the dip in contrast two pictures laid over each other make: the variance this
        /// share of the straight line between the ends or less (a pan or a brightness change stays near 1).
        static let dissolveDip = 0.85
        /// Dissolves and wipes are looked for only between frames at least this different, else noise fits a mix.
        static let blendMinChange = 12.0
        /// A wipe frame: the best straight split's error, as a share of how different the two sides are.
        static let wipeResidual = 0.25
        /// A mixed frame is neither side: at least this share of the difference away from each.
        static let blendAway = 0.3
        /// Feature-print distance to both neighbouring shots this many times their own frame-to-frame distance…
        static let strayDistance = 2.5
        /// …and at least this (Vision's feature prints: same picture ≈ 0, unrelated ones well above).
        static let strayFloor = 0.35
        /// Black this short (frames) with no fade either side: a black flash.
        static let blackFlashFrames = 3.5
        /// Silence within this many seconds of a transition belongs to it.
        static let soundAtTransition = 0.3
        /// Transitions of one kind this close (seconds) are one.
        static let mergeGap = 0.5
    }

    enum TransitionKind: String {
        case dissolve, fadeToBlack, fadeFromBlack, dipToBlack, fadeToWhite, fadeFromWhite, dipToWhite, whipPan, flash, wipe

        var label: String {
            switch self {
            case .dissolve: String(localized: "Dissolve")
            case .fadeToBlack: String(localized: "Fade to black")
            case .fadeFromBlack: String(localized: "Fade from black")
            case .dipToBlack: String(localized: "Dip to black")
            case .fadeToWhite: String(localized: "Fade to white")
            case .fadeFromWhite: String(localized: "Fade from white")
            case .dipToWhite: String(localized: "Dip to white")
            case .whipPan: String(localized: "Whip pan")
            case .flash: String(localized: "Flash")
            case .wipe: String(localized: "Wipe")
            }
        }

        /// Which wins where two overlap: a fade is the clearest reading, a dissolve the loosest.
        var rank: Int {
            switch self {
            case .fadeToBlack, .fadeFromBlack, .dipToBlack, .fadeToWhite, .fadeFromWhite, .dipToWhite: 0
            case .wipe: 1
            case .whipPan: 2
            case .flash: 3
            case .dissolve: 4
            }
        }
    }

    struct Transition {
        var kind: TransitionKind
        var start: Double
        var end: Double
    }

    /// The 64×36 grey frames and what can be measured on them.
    struct Pixels {
        static let w = 64, h = 36, size = w * h
        let base: UnsafePointer<UInt8>
        let count: Int

        func frame(_ i: Int) -> UnsafePointer<UInt8> { base + i * Self.size }

        /// Mean absolute difference (0…255).
        func diff(_ i: Int, _ j: Int) -> Double {
            let a = frame(i), b = frame(j)
            var sum = 0
            for p in 0..<Self.size { sum += abs(Int(a[p]) - Int(b[p])) }
            return Double(sum) / Double(Self.size)
        }

        /// The mix α·a + (1−α)·b closest to frame k, and how far k still is from it (mean absolute).
        func blend(_ k: Int, _ a: Int, _ b: Int) -> (alpha: Double, residual: Double) {
            let g = frame(k), pa = frame(a), pb = frame(b)
            var top = 0.0, bottom = 0.0
            for p in 0..<Self.size {
                let d = Double(pa[p]) - Double(pb[p])
                top += (Double(g[p]) - Double(pb[p])) * d
                bottom += d * d
            }
            let alpha = bottom > 0 ? min(max(top / bottom, 0), 1) : 0.5
            var residual = 0.0
            for p in 0..<Self.size { residual += abs(Double(g[p]) - (alpha * Double(pa[p]) + (1 - alpha) * Double(pb[p]))) }
            return (alpha, residual / Double(Self.size))
        }

        /// The best straight split (columns or rows, between 20 and 80 %) of frame k into a's part
        /// and b's part, as its mean absolute error.
        func wipe(_ k: Int, _ a: Int, _ b: Int) -> Double {
            let g = frame(k), pa = frame(a), pb = frame(b)
            var colA = [Double](repeating: 0, count: Self.w), colB = colA
            var rowA = [Double](repeating: 0, count: Self.h), rowB = rowA
            for y in 0..<Self.h {
                for x in 0..<Self.w {
                    let p = y * Self.w + x
                    let ea = Double(abs(Int(g[p]) - Int(pa[p]))), eb = Double(abs(Int(g[p]) - Int(pb[p])))
                    colA[x] += ea; colB[x] += eb; rowA[y] += ea; rowB[y] += eb
                }
            }
            func best(_ ea: [Double], _ eb: [Double]) -> Double {
                let n = ea.count
                var result = Double.infinity
                for split in Int(Double(n) * 0.2)...Int(Double(n) * 0.8) {
                    let left = ea[..<split].reduce(0, +) + eb[split...].reduce(0, +)
                    let right = eb[..<split].reduce(0, +) + ea[split...].reduce(0, +)
                    result = min(result, left, right)
                }
                return result
            }
            return min(best(colA, colB), best(rowA, rowB)) / Double(Self.size)
        }

        /// Mean horizontal and vertical neighbour difference: how sharp each way.
        func sharpness(_ i: Int) -> (x: Double, y: Double) {
            let g = frame(i)
            var sx = 0, sy = 0
            for y in 0..<Self.h {
                for x in 0..<Self.w {
                    let p = y * Self.w + x
                    if x + 1 < Self.w { sx += abs(Int(g[p + 1]) - Int(g[p])) }
                    if y + 1 < Self.h { sy += abs(Int(g[p + Self.w]) - Int(g[p])) }
                }
            }
            return (Double(sx) / Double((Self.w - 1) * Self.h), Double(sy) / Double(Self.w * (Self.h - 1)))
        }

        /// Standard deviation of the brightness.
        func contrast(_ i: Int) -> Double {
            let g = frame(i)
            var sum = 0.0, squares = 0.0
            for p in 0..<Self.size { let v = Double(g[p]); sum += v; squares += v * v }
            let mean = sum / Double(Self.size)
            return (squares / Double(Self.size) - mean * mean).squareRoot()
        }
    }

    // MARK: - Running ffmpeg

    /// The picture's issues, and the transitions found (for the sound: silence at a transition is fine).
    static func picture(_ file: URL, fps: Double, duration: Double, ffmpeg: String,
                        progress: @escaping @Sendable (Double) -> Void) async -> (issues: [Issue], transitions: [Transition]) {
        if ScreenshotMode.scene != nil { measured = [] }
        let grey = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-delivery-\(UUID().uuidString).gray")
        defer { try? FileManager.default.removeItem(at: grey) }
        // shortcut: the grey copy is 2.3 KB a frame on disk (200 MB for an hour at 25 fps); sample it if hour-long checks get common.
        let graph = "[0:v]scale=320:-2,split[a][b];"
            + "[a]blackdetect=d=0:pix_th=0.1:pic_th=0.98,freezedetect=n=0.001:d=2,scdet=threshold=100,signalstats,metadata=print:file=-[meta];"
            + "[b]scale=\(Pixels.w):\(Pixels.h):flags=area,format=gray[grey]"
        let output = await Self.output(ffmpeg, ["-nostdin", "-v", "error", "-i", file.path, "-an", "-filter_complex", graph,
                                                "-map", "[meta]", "-fps_mode", "passthrough", "-f", "null", "-",
                                                "-map", "[grey]", "-fps_mode", "passthrough", "-f", "rawvideo", "-y", grey.path]) { line in
            if line.hasPrefix("frame:"), let range = line.range(of: "pts_time:"), let t = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
                progress(min(t / max(duration, 1), 1) * 0.9)
            }
        }
        var times: [Double] = [], mafd: [Double] = [], lows: [Double] = [], highs: [Double] = [], averages: [Double] = []
        var blacks: [(Double, Double?)] = [], freezes: [(Double, Double?)] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("frame:") {
                let time = line.range(of: "pts_time:").flatMap { Double(line[$0.upperBound...].trimmingCharacters(in: .whitespaces)) }
                times.append(time ?? (times.last ?? 0) + 1 / max(fps, 1))
                mafd.append(0); lows.append(0); highs.append(255); averages.append(128)
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]), !times.isEmpty else { continue }
            let last = times.count - 1
            switch parts[0] {
            case "lavfi.scd.mafd": mafd[last] = value
            case "lavfi.black_start": blacks.append((value, nil))
            case "lavfi.black_end": if !blacks.isEmpty { blacks[blacks.count - 1].1 = value }
            case "lavfi.freezedetect.freeze_start": freezes.append((value, nil))
            case "lavfi.freezedetect.freeze_end": if !freezes.isEmpty { freezes[freezes.count - 1].1 = value }
            case "lavfi.signalstats.YLOW": lows[last] = value
            case "lavfi.signalstats.YHIGH": highs[last] = value
            case "lavfi.signalstats.YAVG": averages[last] = value
            default: break
            }
        }
        let data = (try? Data(contentsOf: grey, options: .alwaysMapped)) ?? Data()
        let frames = Frames(times: times, mafd: mafd, low: lows, high: highs, average: averages, fps: fps, duration: duration)
        var result = data.withUnsafeBytes { raw -> (issues: [Issue], transitions: [Transition], strays: [Stray]) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return frames.analyse(nil, blacks: blacks) }
            return frames.analyse(Pixels(base: base, count: min(times.count, raw.count / Pixels.size)), blacks: blacks)
        }
        // Frames left between two cuts that are no transition: a stray frame only if it looks like neither shot.
        for stray in result.strays {
            let left = await strayLooksLikeNeither(file, stray: stray, times: times, fps: fps)
            guard left != false else { continue }
            result.issues.append(Issue(severity: .problem, time: times[stray.first], title: String(localized: "Flash frame"),
                                       detail: stray.count == 1 ? String(localized: "A single frame between two shots, probably left over from an edit.")
                                                                : String(localized: "Two frames between two shots, probably left over from an edit."),
                                       kind: .picture))
        }
        progress(1)
        // A picture that stands still in the middle (an end card or a title is fine).
        let frame = 1 / max(fps, 1)
        for (start, endTime) in freezes {
            let end = endTime ?? duration
            guard end < duration - frame * 2, start > frame * 2 else { continue }
            result.issues.append(Issue(severity: .note, time: start, end: end, title: String(localized: "Picture stands still"),
                                       detail: String(localized: "\(String(format: "%.1f", end - start)) seconds without any movement. Fine for a title or a still; check it isn’t a frozen render."),
                                       kind: .picture))
        }
        for transition in result.transitions {
            let length = transition.end - transition.start
            result.issues.append(Issue(severity: .note, time: transition.start, end: transition.end, title: String(localized: "Transition"),
                                       detail: length >= 0.15 ? "\(transition.kind.label), \(String(format: "%.1f", length)) s" : transition.kind.label,
                                       kind: .transition))
        }
        return (result.issues, result.transitions)
    }

    struct Stray {
        var first: Int
        var count: Int
    }

    /// Feature prints of the frames before, the stray ones and after: false when the stray frame
    /// looks like one of the shots around it (motion, not a leftover), nil when it couldn't be told.
    private static func strayLooksLikeNeither(_ file: URL, stray: Stray, times: [Double], fps: Double) async -> Bool? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func print(_ index: Int) async -> VNFeaturePrintObservation? {
            let index = min(max(index, 0), times.count - 1)
            guard let image = try? await generator.image(at: CMTime(seconds: times[index] + 0.3 / max(fps, 1), preferredTimescale: 6000)).image else { return nil }
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.first
        }
        func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double? {
            var value: Float = 0
            return (try? a.computeDistance(&value, to: b)) != nil ? Double(value) : nil
        }
        let before = stray.first - 1, after = stray.first + stray.count
        guard let a2 = await print(before - 2), let a = await print(before), let b = await print(after), let b2 = await print(after + 2),
              let within = [distance(a2, a), distance(b, b2)].compactMap({ $0 }).max() else { return nil }
        let limit = max(Tune.strayFloor, within * Tune.strayDistance)
        for index in stray.first..<after {
            guard let s = await print(index), let toA = distance(s, a), let toB = distance(s, b) else { return nil }
            if ScreenshotMode.scene != nil { DeliveryCheck.measured.append(String(format: "stray %.2f: to before %.3f, to after %.3f, within %.3f", times[index], toA, toB, within)) }
            if min(toA, toB) <= limit { return false }
        }
        return true
    }

    /// What the last check measured on the way, in self-tests only (they check one file at a time; the
    /// app never touches it, so checks running side by side don't share it).
    nonisolated(unsafe) static var measured: [String] = []

    /// Per-frame numbers from ffmpeg, and the classifying.
    struct Frames {
        var times: [Double], mafd: [Double], low: [Double], high: [Double], average: [Double]
        var fps: Double, duration: Double

        var count: Int { times.count }
        func plain(_ i: Int) -> Bool { high[i] - low[i] < Tune.plainRange }

        /// A big change from the frame before, against the frames around it.
        func cut(_ i: Int) -> Bool {
            guard i > 0, i < mafd.count else { return false }
            let window = mafd[max(0, i - 12)..<min(mafd.count, i + 13)].sorted()
            return mafd[i] >= max(Tune.cutFloor, window[window.count / 2] * Tune.cutFactor)
        }

        /// How many frames from `edge` (going `step`) brighten away from a black run, or darken away
        /// from a white one, the way a fade does. 0 when it's a cut.
        func ramp(from edge: Int, step: Int, runLevel: Double, white: Bool) -> Int {
            var n = 0, j = edge, previous = runLevel
            let longest = Int(Tune.rampLongest * max(fps, 1))
            while j >= 0, j < count, n < longest {
                let change = white ? previous - average[j] : average[j] - previous
                guard change > 0.3 else { break }
                previous = average[j]
                n += 1
                j += step
            }
            guard n >= Tune.rampFrames else { return 0 }
            let total = abs(previous - runLevel), first = abs(average[edge] - runLevel)
            return total >= Tune.rampRise && first <= Tune.rampLastStep * total ? n : 0
        }

        func analyse(_ pixels: Pixels?, blacks: [(Double, Double?)]) -> (issues: [Issue], transitions: [Transition], strays: [Stray]) {
            var issues: [Issue] = [], transitions: [Transition] = [], strays: [Stray] = []
            let frame = 1 / max(fps, 1)
            func index(_ time: Double) -> Int { times.firstIndex { $0 >= time - frame * 0.5 } ?? count }
            func time(_ index: Int) -> Double { index < count ? times[index] : duration }
            /// Frames inside black, a white run, or a transition: already explained.
            var explained = [Bool](repeating: false, count: count)
            func mark(_ from: Int, _ to: Int) { for i in max(from, 0)..<min(to, count) { explained[i] = true } }

            // Black and white runs, with or without a fade either side.
            var runs: [(start: Int, end: Int, white: Bool)] = blacks.map { (index($0.0), index($0.1 ?? duration), false) }
            var i = 0
            while i < count {
                if plain(i), average[i] > Tune.whiteLevel {
                    var j = i
                    while j < count, plain(j), average[j] > Tune.whiteLevel { j += 1 }
                    runs.append((i, j, true))
                    i = j
                } else { i += 1 }
            }
            for run in runs where run.end > run.start {
                let level = average[min(run.start, count - 1)]
                let before = run.start > 0 ? ramp(from: run.start - 1, step: -1, runLevel: level, white: run.white) : 0
                let after = run.end < count ? ramp(from: run.end, step: 1, runLevel: level, white: run.white) : 0
                let start = time(run.start), end = time(run.end), length = end - start
                let atStart = start < frame * 1.5, atEnd = end > duration - frame * 1.5
                mark(run.start - before, run.end + after)
                let kind: TransitionKind?
                switch (before > 0, after > 0) {
                case (true, true): kind = run.white ? .dipToWhite : .dipToBlack
                case (true, false): kind = run.white ? .fadeToWhite : .fadeToBlack
                case (false, true): kind = run.white ? .fadeFromWhite : .fadeFromBlack
                case (false, false): kind = nil
                }
                if let kind {
                    transitions.append(Transition(kind: kind, start: time(run.start - before), end: time(run.end + after)))
                } else if run.white {
                    // White cut in and out: a flash if it's short, else a white card.
                    if !atStart, !atEnd, length < 0.3 { transitions.append(Transition(kind: .flash, start: start, end: end)) }
                } else if atStart || atEnd {
                    if length > 2 {
                        issues.append(Issue(severity: .note, time: start, end: end,
                                            title: atStart ? String(localized: "Black at the start") : String(localized: "Black at the end"),
                                            detail: String(localized: "\(String(format: "%.1f", length)) seconds of black. Some platforms pick a black first frame as the thumbnail."),
                                            kind: .picture))
                    }
                } else if length < frame * Tune.blackFlashFrames {
                    issues.append(Issue(severity: .problem, time: start, end: end, title: String(localized: "Black flash"),
                                        detail: String(localized: "A frame or two of black in the middle of the video."), kind: .picture))
                } else {
                    issues.append(Issue(severity: .warning, time: start, end: end, title: String(localized: "Black"),
                                        detail: String(localized: "\(String(format: "%.1f", length)) seconds of black. Fine if it’s meant as a pause."),
                                        kind: .picture))
                }
            }

            guard let pixels else { return (issues, merge(transitions), strays) }
            let n = min(pixels.count, count)
            let sharp = (0..<n).map { pixels.sharpness($0) }
            let contrast = (0..<n).map { pixels.contrast($0) }
            func median(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.sorted()[values.count / 2] }

            // Around each cut: blurred frames (a whip pan) or bright, washed-out ones (a flash, a light leak).
            let cuts = (1..<max(n, 1)).filter { cut($0) }
            for c in cuts {
                func reference(_ range: Range<Int>) -> (x: Double, y: Double, avg: Double, contrast: Double)? {
                    let r = max(range.lowerBound, 0)..<min(range.upperBound, n)
                    guard !r.isEmpty, let x = median(r.map { sharp[$0].x }), let y = median(r.map { sharp[$0].y }),
                          let a = median(r.map { average[$0] }), let k = median(r.map { contrast[$0] }) else { return nil }
                    return (x, y, a, k)
                }
                let far = Tune.aroundCut + 1
                guard let before = reference((c - far - 7)..<(c - far)) ?? reference(0..<c),
                      let after = reference((c + far)..<(c + far + 7)) ?? reference(c..<n) else { continue }
                func blurred(_ j: Int, _ ref: (x: Double, y: Double, avg: Double, contrast: Double)) -> Bool {
                    let rx = sharp[j].x / max(ref.x, 0.5), ry = sharp[j].y / max(ref.y, 0.5)
                    return min(rx, ry) < Tune.blurShare && max(rx, ry) > Tune.blurDirection * min(rx, ry)
                }
                func bright(_ j: Int, _ ref: (x: Double, y: Double, avg: Double, contrast: Double)) -> Bool {
                    average[j] >= ref.avg + Tune.flashRise && contrast[j] <= Tune.flashContrast * ref.contrast
                }
                func run(_ test: (Int) -> Bool, from: Int, step: Int) -> Int {
                    var k = 0
                    while k < Tune.aroundCut, from + k * step >= 0, from + k * step < n, test(from + k * step) { k += 1 }
                    return k
                }
                // (Bright first: washed-out frames are soft too.)
                let brightBefore = run({ bright($0, before) }, from: c - 1, step: -1), brightAfter = run({ bright($0, after) }, from: c, step: 1)
                // A short run of them either side (the cut can fall at the brightest moment or before it).
                if brightBefore + brightAfter > 0, brightBefore < Tune.aroundCut, brightAfter < Tune.aroundCut {
                    transitions.append(Transition(kind: .flash, start: time(c - brightBefore), end: time(c + brightAfter)))
                    mark(c - brightBefore, c + brightAfter)
                    continue
                }
                let blurBefore = run({ blurred($0, before) && !bright($0, before) }, from: c - 1, step: -1)
                let blurAfter = run({ blurred($0, after) && !bright($0, after) }, from: c, step: 1)
                if blurBefore + blurAfter >= 2 {
                    transitions.append(Transition(kind: .whipPan, start: time(c - blurBefore), end: time(c + blurAfter)))
                    mark(c - blurBefore, c + blurAfter)
                }
            }

            // Dissolves and wipes: a frame that's a mix (or a split) of the frames either side, and the
            // frames halfway to them further along the same way.
            var mixed: [(Int, TransitionKind)] = []
            for i in 0..<n {
                for k in [4, 10] where i - k >= 0 && i + k < n {
                    let a = i - k, b = i + k
                    let change = pixels.diff(a, b)
                    guard change > Tune.blendMinChange,
                          pixels.diff(i, a) > Tune.blendAway * change, pixels.diff(i, b) > Tune.blendAway * change else { continue }
                    let q1 = i - k / 2, q3 = i + k / 2
                    let wipe = pixels.wipe(i, a, b)
                    let (alpha, residual) = pixels.blend(i, a, b)
                    if wipe < Tune.wipeResidual * change, wipe * 2 < residual,
                       pixels.wipe(q1, a, b) < Tune.wipeResidual * change, pixels.wipe(q3, a, b) < Tune.wipeResidual * change {
                        mixed.append((i, .wipe))
                        break
                    }
                    let line = alpha * contrast[a] * contrast[a] + (1 - alpha) * contrast[b] * contrast[b]
                    guard (0.2...0.8).contains(alpha), residual < Tune.dissolveResidual * change,
                          contrast[i] * contrast[i] < Tune.dissolveDip * line else { continue }
                    let first = pixels.blend(q1, a, b), last = pixels.blend(q3, a, b)
                    if first.alpha > alpha + 0.1, last.alpha < alpha - 0.1,
                       first.residual < 1.25 * Tune.dissolveResidual * change, last.residual < 1.25 * Tune.dissolveResidual * change {
                        mixed.append((i, .dissolve))
                        break
                    }
                }
            }
            var m = 0
            while m < mixed.count {
                var last = m
                while last + 1 < mixed.count, mixed[last + 1].0 - mixed[last].0 <= 3, mixed[last + 1].1 == mixed[m].1 { last += 1 }
                if last > m {
                    let from = mixed[m].0 - 2, to = mixed[last].0 + 3
                    if !explained[max(from, 0)..<min(to, n)].allSatisfy({ $0 }) {
                        transitions.append(Transition(kind: mixed[m].1, start: time(max(from, 0)), end: time(min(to, n))))
                    }
                    mark(from, to)
                }
                m = last + 1
            }

            // One or two frames between two cuts, not explained by anything above: plain (a flash),
            // a mix, blurred or washed out (a short transition), or else maybe left over.
            var c = 1
            while c < n - 1 {
                guard cut(c), let frames = (1...Tune.strayFrames).first(where: { cut(c + $0) }) else { c += 1; continue }
                let range = c..<min(c + frames, n)
                let a = c - 1, b = min(c + frames, n - 1)
                defer { c += frames }
                if range.contains(where: { explained[$0] }) { continue }
                let change = pixels.diff(a, b)
                func shortTransition(_ j: Int) -> TransitionKind? {
                    if plain(j) { return .flash }
                    let (alpha, residual) = pixels.blend(j, a, b)
                    if change > Tune.blendMinChange, (0.1...0.9).contains(alpha), residual < Tune.blendResidual * change { return .dissolve }
                    if average[j] >= max(average[a], average[b]) + Tune.flashRise,
                       contrast[j] <= Tune.flashContrast * max(contrast[a], contrast[b]) { return .flash }
                    let rx = sharp[j].x / max(sharp[a].x, sharp[b].x, 0.5), ry = sharp[j].y / max(sharp[a].y, sharp[b].y, 0.5)
                    if min(rx, ry) < Tune.blurShare, max(rx, ry) > Tune.blurDirection * min(rx, ry) { return .whipPan }
                    if change > Tune.blendMinChange, pixels.wipe(j, a, b) < Tune.wipeResidual * change { return .wipe }
                    return nil
                }
                let kinds = range.map(shortTransition)
                if let kind = kinds.first ?? nil, kinds.allSatisfy({ $0 != nil }) {
                    transitions.append(Transition(kind: kind, start: time(c), end: time(c + frames)))
                } else {
                    strays.append(Stray(first: c, count: frames))
                }
            }
            return (issues, merge(transitions), strays)
        }

        /// One transition per moment: the same kind close together is one, and where kinds overlap the clearest reading wins.
        func merge(_ transitions: [Transition]) -> [Transition] {
            var result: [Transition] = []
            for item in transitions.sorted(by: { ($0.kind.rank, $0.start) < ($1.kind.rank, $1.start) }) {
                if let index = result.firstIndex(where: { $0.kind == item.kind && item.start <= $0.end + Tune.mergeGap && $0.start <= item.end + Tune.mergeGap }) {
                    result[index].start = min(result[index].start, item.start)
                    result[index].end = max(result[index].end, item.end)
                } else if !result.contains(where: { item.start < $0.end && $0.start < item.end }) {
                    result.append(item)
                }
            }
            return result.sorted { $0.start < $1.start }
        }
    }
}
