import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension LogoAnimation {
    /// The moments of a plan that golden frames are taken at (as parts of its length).
    static let goldenMoments: [Double] = [0, 0.08, 0.16, 0.25, 0.4, 0.6, 0.85, 1]

    /// Renders every style and outro of every logo in `folder` at the golden moments into `output`:
    /// a small PNG of each and a line per frame in manifest.txt with a hash of its pixels, so a
    /// change to the motion code can be checked frame for frame against the last build (`baseline`:
    /// its folder, for a report of the frames that differ).
    static func renderGoldenFrames(from folder: URL, to output: URL, baseline: URL? = nil) {
        let logos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["svg", "pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = CGSize(width: 320, height: 180)
        var manifest: [String] = [], report: [String] = []
        var worst: (difference: Int, share: Double, key: String) = (0, 0, "")
        for logo in logos {
            let name = logo.deletingPathExtension().lastPathComponent
            guard let animation = try? LogoAnimation(contentsOf: logo) else {
                manifest.append("\(name)\tunreadable")
                continue
            }
            let pictures = output.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            // -PluckScreenshotFull: the finished logo and a moment of Elegant at 4K too, to judge sharpness.
            if UserDefaults.standard.bool(forKey: "PluckScreenshotFull") {
                let plan = animation.plan(.elegant, outro: .none), uhd = CGSize(width: 3840, height: 2160)
                for (label, t) in [("final", plan.total), ("moment", plan.total * 0.25)] {
                    if let image = animation.frame(at: t, plan: plan, size: uhd, background: CGColor(gray: 1, alpha: 1)),
                       let destination = CGImageDestinationCreateWithURL(pictures.appendingPathComponent("\(label)-4k.png") as CFURL,
                                                                         UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                    }
                }
            }
            // Each style's spec, to read.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            for style in Style.allCases {
                if let spec = animation.motionSpec(for: style), let json = try? encoder.encode(spec) {
                    try? json.write(to: pictures.appendingPathComponent("spec-\(style.rawValue).json"))
                }
            }
            for style in Style.allCases where style != .automatic && style != .designed {
                for outro in Outro.allCases {
                    let plan = animation.plan(style, outro: outro)
                    for (index, moment) in goldenMoments.enumerated() {
                        let key = "\(style.rawValue)-\(outro.rawValue)-\(index)"
                        guard let image = animation.frame(at: plan.total * moment, plan: plan, size: size, background: nil),
                              let data = image.dataProvider?.data as Data? else {
                            manifest.append("\(name)\t\(key)\tnone")
                            continue
                        }
                        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
                        manifest.append("\(name)\t\(key)\t\(hash)")
                        if let baseline, let old = pixels(baseline.appendingPathComponent(name).appendingPathComponent(key + ".png")),
                           let new = pixels(image), old.count == new.count {
                            // The largest difference in any channel, and the share of pixels off by more than 8.
                            var largest = 0, off = 0
                            for i in stride(from: 0, to: old.count, by: 4) {
                                var pixel = 0
                                for c in 0..<4 { pixel = max(pixel, abs(Int(old[i + c]) - Int(new[i + c]))) }
                                largest = max(largest, pixel)
                                if pixel > 8 { off += 1 }
                            }
                            let share = Double(off) / Double(old.count / 4)
                            if share > 0.001 { report.append("\(name)\t\(key)\tmax \(largest)\toff \(String(format: "%.3f", share * 100))%") }
                            if share > worst.share || (share == worst.share && largest > worst.difference) { worst = (largest, share, "\(name) \(key)") }
                        }
                        let file = pictures.appendingPathComponent(key + ".png") as CFURL
                        if let destination = CGImageDestinationCreateWithURL(file, UTType.png.identifier as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            CGImageDestinationFinalize(destination)
                        }
                    }
                }
            }
        }
        try? manifest.joined(separator: "\n").write(to: output.appendingPathComponent("manifest.txt"), atomically: true, encoding: .utf8)
        if baseline != nil {
            report.insert("worst: \(worst.key), max \(worst.difference), \(String(format: "%.3f", worst.share * 100))% of pixels off by more than 8", at: 0)
        }
        report += checks(logos)
        try? report.joined(separator: "\n").write(to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    /// The other checks: every spec survives JSON unchanged, and fitting a length never slows the
    /// moves down.
    private static func checks(_ logos: [URL]) -> [String] {
        var lines: [String] = []
        var roundTrips = 0, slowed = 0
        for logo in logos {
            guard let animation = try? LogoAnimation(contentsOf: logo) else { continue }
            if ["svg", "pdf"].contains(logo.pathExtension.lowercased()) {
                let parts = animation.elements.filter { $0.vector != nil }.count
                for element in animation.elements where element.vector == nil && animation.artDifference.map({ $0 < 0.01 }) == true {
                    lines.append("  no vector: \(element.kind) at \(element.box.integral)")
                }
                // Save as SVG writes the shapes as they are: read back, they draw the same logo.
                if let shapes = animation.vectorLogo {
                    let saved = FileManager.default.temporaryDirectory.appendingPathComponent("golden-\(UUID().uuidString).svg")
                    try? animation.svg().write(to: saved, atomically: true, encoding: .utf8)
                    let back = VectorArt(contentsOf: saved)
                    try? FileManager.default.removeItem(at: saved)
                    let w = Int(animation.size.width), h = Int(animation.size.height)
                    if let back, let a = render(shapes, width: w, height: h, transform: .identity) {
                        lines.append(String(format: "  saved SVG vs drawn: %.2f%%", artDifference(back, picture: a, width: w, height: h, scale: CGSize(width: 1, height: 1)) * 100))
                    } else {
                        lines.append("  saved SVG unreadable")
                    }
                }
                lines.append("vectors \(logo.lastPathComponent): \(parts) of \(animation.elements.count) parts\(animation.vectorLogo != nil ? ", whole logo" : "")\(animation.artDifference.map { String(format: ", file vs system picture %.2f%%", $0 * 100) } ?? ", not read")")
            }
            for style in Style.allCases {
                if let spec = animation.motionSpec(for: style) {
                    let decoded = (try? JSONEncoder().encode(spec)).flatMap { try? JSONDecoder().decode(MotionSpec.self, from: $0) }
                    if decoded == spec { roundTrips += 1 } else { lines.append("round trip failed: \(logo.lastPathComponent) \(style.rawValue)") }
                    for outro in Outro.allCases {
                        for length in [1.0, 2, 3, 5, 10, 20] where animation.plan(.custom(spec), outro: outro, length: length).speed < 1 {
                            slowed += 1
                        }
                    }
                }
                for outro in Outro.allCases {
                    for length in [1.0, 2, 3, 5, 10, 20] where animation.plan(style, outro: outro, length: length).speed < 1 { slowed += 1 }
                }
            }
        }
        // A spec played as a custom source draws exactly as its template.
        var same = 0, differ = 0
        for logo in logos.prefix(6) {
            guard let animation = try? LogoAnimation(contentsOf: logo) else { continue }
            for style in specStyles {
                guard let spec = animation.motionSpec(for: style) else { continue }
                for outro in Outro.allCases {
                    let template = animation.plan(style, outro: outro), custom = animation.plan(.custom(spec), outro: outro)
                    for moment in goldenMoments {
                        let a = animation.frame(at: template.total * moment, plan: template, size: CGSize(width: 320, height: 180), background: nil)
                        let b = animation.frame(at: custom.total * moment, plan: custom, size: CGSize(width: 320, height: 180), background: nil)
                        if let a, let b, pixels(a) == pixels(b) { same += 1 } else { differ += 1 }
                    }
                }
            }
        }
        lines.append("custom = template: \(same) same, \(differ) differ")
        // The Bézier curves: (0, 0, 1, 1) is a straight line, and the named ones rise from 0 to 1.
        let line = stride(from: 0.0, through: 1, by: 0.05).map { abs(Easing.bezier(0, 0, 1, 1, $0) - $0) }.max() ?? 1
        var rising = true
        for ease in [MotionSpec.Ease.calm, .premium, .bold] {
            let values = stride(from: 0.0, through: 1, by: 0.01).map { ease($0) }
            if values.first != 0 || values.last != 1 || zip(values, values.dropFirst()).contains(where: { $1 < $0 - 1e-9 }) { rising = false }
        }
        lines.append("bezier: straight line off by \(String(format: "%.2g", line)); named curves rise: \(rising)")
        lines.append("round trips: \(roundTrips) ok")
        lines.append("plans slower than designed: \(slowed)")
        return lines
    }

    /// An image's pixels as premultiplied RGBA, 8 bits.
    private static func pixels(_ url: URL) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return pixels(image)
    }

    private static func pixels(_ image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? bytes : nil
    }
}

extension LogoAnimation {
    /// The profile of every logo in `folder`, as JSON lines in `output` (to compare with labels).
    static func writeProfiles(from folder: URL, to output: URL) {
        let logos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["svg", "pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var lines: [String] = []
        for logo in logos {
            guard let animation = try? LogoAnimation(contentsOf: logo) else {
                lines.append("{\"file\":\"\(logo.lastPathComponent)\",\"unreadable\":true}")
                continue
            }
            let p = animation.profile
            let hero: String
            if p.hero.allSatisfy({ p.roles[$0] == .symbol }) && !p.hero.isEmpty { hero = "symbol" }
            else if p.hero.allSatisfy({ p.roles[$0] == .plate }) && !p.hero.isEmpty { hero = "plate" }
            else if p.hero.count == 1, animation.elements[p.hero[0]].spark { hero = "spark" }
            else { hero = "letter" }
            let record: [String: Any] = [
                "file": logo.lastPathComponent,
                "layout": p.layout.rawValue,
                "hero": hero,
                "heroShape": p.heroShape?.rawValue ?? "mixed",
                "mirrored": p.heroSymmetry.isMirrored,
                "mirror": (p.heroSymmetry.mirror * 100).rounded() / 100,
                "turns": p.heroSymmetry.turns,
                "facing": p.facing.rawValue,
                "tagline": p.hasTagline,
                "serif": p.metrics.serif,
                "contrast": (p.metrics.contrast * 100).rounded() / 100,
                "roundness": (p.metrics.roundness * 100).rounded() / 100,
                "weight": (p.metrics.weight * 1000).rounded() / 1000,
                "saturation": (p.metrics.saturation * 100).rounded() / 100,
                "colours": p.metrics.colours,
                "personality": p.personality().rawValue,
                "repeats": p.repeats.map(\.count),
                "templateOnly": p.templateOnly,
                "roles": p.roles.map(\.rawValue),
                "summary": p.summary,
                "art": animation.artDifference.map { ($0 * 10000).rounded() / 100 } ?? -1,
                "vectorParts": animation.elements.filter { $0.vector != nil }.count,
                "ends": {
                    let e = PartMask.union(p.hero.map { PartMask(animation.elements[$0]) }).endWidths()
                    return [e.left, e.right, e.top, e.bottom].map { ($0 * 100).rounded() / 100 }
                }(),
                "parts": animation.elements.indices.map { i -> String in
                    let e = animation.elements[i]
                    return "\(p.roles[i].rawValue)/\(e.kind)/\(p.shapes[i].rawValue)\(e.guessedLetter ? "?" : "")\(e.spark ? "*" : "") \(Int(e.box.minX)),\(Int(e.box.minY)) \(Int(e.box.width))x\(Int(e.box.height))"
                },
                "symmetryScores": [p.heroSymmetry.mirror, p.heroSymmetry.flip].map { ($0 * 100).rounded() / 100 },
                "heroVector": p.hero.map { animation.elements[$0].vector.map { $0.map(\.stroke).description } ?? "none" },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { lines.append(String(decoding: data, as: UTF8.self)) }
        }
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}

extension LogoAnimation {
    /// Designs three ideas for every logo in `folder`: a JSON line each in `output`/designs.jsonl
    /// (name, fit, whether the last frame is the logo, whether the same seed gives the same
    /// design) and a strip of eight frames of the first idea (`output`/<logo>.png).
    static func writeDesigns(from folder: URL, to output: URL) {
        let logos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["svg", "pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        for logo in logos {
            guard let animation = try? LogoAnimation(contentsOf: logo) else { continue }
            var record: [String: Any] = ["file": logo.lastPathComponent, "templateOnly": animation.profile.templateOnly,
                                         "summary": animation.profile.summary, "personality": animation.profile.personality().rawValue,
                                         "moves": animation.heroMoves().map { "\($0.move.rawValue) \(String(format: "%.2f", $0.score))" }]
            var ideas: [[String: Any]] = []
            for seed in 0..<3 {
                guard let design = animation.design(seed: seed) else { continue }
                let again = animation.design(seed: seed)
                ideas.append(["seed": seed, "name": design.name, "score": design.score, "valid": design.valid,
                              "same": again?.spec == design.spec, "length": (design.spec.duration * 100).rounded() / 100])
                if seed == 0 { strip(animation, design, to: output.appendingPathComponent(logo.deletingPathExtension().lastPathComponent + ".png")) }
            }
            record["ideas"] = ideas
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { lines.append(String(decoding: data, as: UTF8.self)) }
        }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("designs.jsonl"), atomically: true, encoding: .utf8)
    }

    /// Eight moments of a design side by side, on grey (the last one past the end).
    private static func strip(_ animation: LogoAnimation, _ design: Design, to url: URL) {
        let frame = CGSize(width: 240, height: 135), count = 8
        guard let context = CGContext(data: nil, width: Int(frame.width) * count, height: Int(frame.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: frame.width * Double(count), height: frame.height))
        let plan = animation.plan(.custom(design.spec), outro: .none)
        for k in 0..<count {
            let t = plan.intro * Double(k) / Double(count - 2)
            guard let image = animation.frame(at: t, plan: plan, size: frame, background: nil) else { continue }
            context.draw(image, in: CGRect(x: frame.width * Double(k), y: 0, width: frame.width, height: frame.height))
        }
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

extension LogoAnimation {
    /// Random edits to every logo's design in `folder` (ten sets each): whether each still ends
    /// on the logo, and whether saving and reading them back gives the same design. One line of
    /// results in `output`.
    static func checkEdits(from folder: URL, to output: URL) {
        let logos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["svg", "pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var tried = 0, valid = 0, restored = 0, failures: [String] = []
        for logo in logos {
            guard let animation = try? LogoAnimation(contentsOf: logo), animation.design() != nil else { continue }
            var random = SeededRandom(seed: UInt64(logo.lastPathComponent.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) }))
            for n in 0..<10 {
                var edits = LogoDesignEdits(feel: LogoProfile.Personality.allCases[Int(random.next() * 4)], seed: n)
                let moves = animation.heroMoves().map(\.move)
                if random.next() < 0.5, !moves.isEmpty { edits.hero = moves[Int(random.next() * Double(moves.count))] }
                for part in animation.elements.indices where random.next() < 0.35 {
                    var edit = LogoDesignEdits.PartEdit()
                    edit.delay = (random.next() - 0.4) * 0.8
                    edit.length = 0.5 + random.next() * 1.5
                    if random.next() < 0.4 { edit.from = LogoDesignEdits.Direction.allCases[Int(random.next() * 4)] }
                    if random.next() < 0.4 { edit.motion = LogoDesignEdits.Motion.allCases[Int(random.next() * 5)] }
                    if random.next() < 0.4 { edit.ease = LogoDesignEdits.Ease.allCases[Int(random.next() * 3)] }
                    edits.parts[part] = edit
                }
                tried += 1
                guard let design = animation.design(edits: edits) else { continue }
                if design.valid { valid += 1 } else { failures.append("\(logo.lastPathComponent) #\(n)") }
                // Kept and read back: the same design.
                LogoDesignStore.save(edits, for: logo)
                if let back = LogoDesignStore.load(for: logo), animation.design(edits: back)?.spec == design.spec { restored += 1 }
            }
            LogoDesignStore.save(LogoDesignEdits(), for: logo)
        }
        let line = "edits tried \(tried), last frame is the logo \(valid), restored the same \(restored)" + (failures.isEmpty ? "" : "; failed: " + failures.prefix(20).joined(separator: ", "))
        try? line.write(to: output, atomically: true, encoding: .utf8)
    }
}

extension LogoAnimation {
    /// Phase 6 checks for every logo in `folder`, written as lines to `output`/outputs.txt: each
    /// output's length and last frame, the loop's ends, the sound's hit against the resolve at four
    /// frame rates, the stacked layout in the safe zone; and the first logo written as every kind of
    /// file (with a hit) into `output`, for checking with ffprobe.
    static func checkOutputs(from folder: URL, to output: URL, ffmpeg: String) async {
        let logos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["svg", "pdf", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        let canvas = CGSize(width: 480, height: 270)
        func pixels(_ image: CGImage?) -> [UInt8] {
            guard let image else { return [] }
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                    .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        func off(_ a: [UInt8], _ b: [UInt8]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return 1 }
            var n = 0
            for i in stride(from: 0, to: a.count, by: 4) where (0..<4).contains(where: { abs(Int(a[i + $0]) - Int(b[i + $0])) > 24 }) { n += 1 }
            return Double(n) / Double(a.count / 4)
        }
        for logo in logos {
            guard let animation = try? LogoAnimation(contentsOf: logo) else { continue }
            let name = logo.lastPathComponent
            let still = pixels(animation.frame(at: 99, plan: animation.plan(.automatic, outro: .none), size: canvas, background: nil))
            for kind in [LogoOutput.reveal, .intro, .sting] {
                guard let design = animation.design(pace: kind.pace) else { continue }
                let plan = animation.plan(.custom(design.spec), outro: .none, length: kind.length)
                let last = pixels(animation.frame(at: plan.total, plan: plan, size: canvas, background: nil))
                // (The moves themselves end on the logo too, before the hand-off to the exact picture.)
                lines.append(String(format: "%@\t%@\tlength %.2f s, moves %.2f s, sped up %.2fx, last frame off %.4f, design ends on logo %@",
                                    name, kind.rawValue, plan.total, design.spec.duration, plan.speed, off(last, still), design.valid ? "yes" : "no"))
            }
            // The loop: its first frame and the frame after its last match.
            let loop = animation.loopPlan()
            let first = pixels(animation.frame(at: 0, plan: loop, size: canvas, background: nil))
            let wrap = pixels(animation.frame(at: loop.total - 0.0001, plan: loop, size: canvas, background: nil))
            lines.append(String(format: "%@\tloop\tperiod %.1f s, first vs end off %.4f, first vs logo off %.4f", name, loop.total, off(first, wrap), off(first, still)))
            // The hit against the resolve at four frame rates.
            if let design = animation.design() {
                let plan = animation.plan(.custom(design.spec), outro: .none, length: 3)
                let resolve = animation.resolveTime(of: plan)
                var errors: [String] = []
                for rate in [25, 30, 50, 60] {
                    let wav = output.appendingPathComponent("hit-\(rate).wav")
                    try? LogoSound.hit.write(to: wav, length: plan.total, resolve: resolve, feel: animation.profile.personality())
                    guard let data = try? Data(contentsOf: wav) else { continue }
                    // The first loud sample, as a video frame, against the resolve's frame.
                    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                    let onset = (samples.indices.first { abs(Int(samples[$0])) > 300 } ?? 0) / 2
                    let onsetFrame = Double(onset) / Double(LogoSound.sampleRate) * Double(rate)
                    errors.append(String(format: "%d fps %.2f frames", rate, abs(onsetFrame - resolve * Double(rate))))
                    try? FileManager.default.removeItem(at: wav)
                }
                lines.append("\(name)\thit\t" + errors.joined(separator: ", "))
            }
            // Stacked for 9:16, inside the safe zone.
            let tall = CGSize(width: 1080, height: 1920)
            let stacked = animation.stacked()
            let rect = (stacked ?? animation).logoRect(canvas: tall)
            lines.append("\(name)\tvertical\t\(stacked == nil ? "not stacked" : "stacked") \(Int(rect.width))x\(Int(rect.height)), in safe zone \(insideSafeZone(rect, canvas: tall) ? "yes" : "no")")
        }
        // Every kind of file, for the first logo.
        if let logo = logos.first, let animation = try? LogoAnimation(contentsOf: logo), let design = animation.design() {
            let plan = animation.plan(.custom(design.spec), outro: .none, length: 2)
            let still = output.appendingPathComponent("still.png")
            if let image = animation.frame(at: plan.total, plan: plan, size: CGSize(width: 640, height: 360), background: nil),
               let destination = CGImageDestinationCreateWithURL(still as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
            let wav = output.appendingPathComponent("sound.wav")
            try? LogoSound.whoosh.write(to: wav, length: plan.total, resolve: animation.resolveTime(of: plan), feel: .bold)
            for kind in LogoFile.allCases where kind != .automatic {
                let target = kind == .pngSequence ? output.appendingPathComponent("file-\(kind.rawValue)")
                    : output.appendingPathComponent("file-\(kind.rawValue).\(kind.fileExtension)")
                do {
                    try await animation.export(to: target, plan: plan, size: CGSize(width: 640, height: 360), frameRate: 30, background: nil,
                                               ffmpeg: ffmpeg, file: kind, audio: wav) { _ in }
                    lines.append("file\t\(kind.rawValue)\twritten")
                } catch {
                    lines.append("file\t\(kind.rawValue)\tfailed: \(error.localizedDescription)")
                }
            }
        }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("outputs.txt"), atomically: true, encoding: .utf8)
    }
}

extension LogoAnimation {
    /// Brand Pack with the Logo Animator's designs: with nothing saved, the end card exactly as
    /// before; with a saved design, the same sting as the Logo Animator; and an end card written with
    /// a sound. Lines to `output`/brandpack.txt.
    static func checkBrandPack(_ logo: URL, to output: URL, ffmpeg: String) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        guard let animation = try? LogoAnimation(contentsOf: logo) else { return }
        let canvas = CGSize(width: 640, height: 360)
        func frames(_ pack: BrandPack) -> [Data] {
            let length = pack.length(.endCard(line: "example.com"))
            return (0...8).map { k -> Data in
                let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                pack.draw(.endCard(line: "example.com"), at: length * Double(k) / 8, in: context, canvas: canvas)
                return context.makeImage()?.dataProvider?.data as Data? ?? Data()
            }
        }
        LogoDesignStore.save(LogoDesignEdits(), for: logo)
        let before = BrandPack(logo: animation, font: "Helvetica Neue", lowerThirdStyle: .plate, background: nil)
        var after = before
        after.endMotion = animation.suggestedMotion(savedFor: logo)
        lines.append("nothing saved: end card frames identical to before \(frames(before) == frames(after) ? "yes" : "no")")
        // A saved design: the end card plays the Logo Animator's sting of it.
        let edits = LogoDesignEdits(feel: .bold, seed: 1)
        LogoDesignStore.save(edits, for: logo)
        let motion = animation.suggestedMotion(savedFor: logo)
        let sting = animation.design(edits: edits, pace: LogoOutput.sting.pace)
        if case .custom(let spec) = motion.plan.source, let sting {
            lines.append("saved design: end card uses the Logo Animator's sting \(spec == sting.spec ? "yes" : "no"), length \(String(format: "%.2f", motion.plan.total)) s, feel \(motion.feel.rawValue)")
        } else {
            lines.append("saved design: not used")
        }
        // Written with a sound.
        var pack = before
        pack.endMotion = motion
        pack.endSound = .whoosh
        do {
            let written = try await pack.export([.endCard(line: "example.com")], to: output.appendingPathComponent("pack"), size: canvas, frameRate: 30, ffmpeg: ffmpeg) { _ in }
            lines.append("end card with sound written: \(written.map(\.lastPathComponent).joined(separator: ", "))")
        } catch {
            lines.append("end card with sound failed: \(error.localizedDescription)")
        }
        LogoDesignStore.save(LogoDesignEdits(), for: logo)
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("brandpack.txt"), atomically: true, encoding: .utf8)
    }
}
