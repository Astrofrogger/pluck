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
            for style in Style.allCases where style != .automatic {
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
                        lines.append(String(format: "  saved SVG vs drawn: %.2f%%", artDifference(back, picture: a, width: w, height: h, scale: 1) * 100))
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
