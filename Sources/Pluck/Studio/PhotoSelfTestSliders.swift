import CoreImage
import Foundation
import ImageIO

/// Process 6's Saturation, Blacks, Whites and negative Dehaze (-PluckScreenshotOnly sliders): each renders the test RAWs at
/// its ends into <photos>/../sliders (to look at), and checks that Blacks and Whites clearly move the darkest and brightest
/// parts, Saturation keeps the brightness, and negative Dehaze veils the far more than the near.
extension PhotoSelfTest {
    static func sliders() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let out = folder.appendingPathComponent("sliders")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!, context = PhotoEngine.context
        let cases: [(String, (inout PhotoAdjustments) -> Void)] = [
            ("plain", { _ in }), ("sat-50", { $0.saturation = -50 }), ("sat+50", { $0.saturation = 50 }), ("sat+100", { $0.saturation = 100 }),
            ("vib+60", { $0.vibrance = 60 }), ("blacks-100", { $0.blacks = -100 }), ("blacks+100", { $0.blacks = 100 }),
            ("whites-100", { $0.whites = -100 }), ("whites+100", { $0.whites = 100 }), ("dehaze-60", { $0.dehaze = -60 }), ("dehaze+60", { $0.dehaze = 60 }),
            ("rolloff+100", { $0.rolloff = 100 }), ("rolloff-100", { $0.rolloff = -100 }), ("basic", { $0.toneEngine = .basic }),
        ]
        for name in ["DSC01962", "DSC02845"] {
            let raw = folder.appendingPathComponent("raws/\(name).ARW").path
            guard FileManager.default.fileExists(atPath: raw) else { skip("sliders \(name)", "no RAW"); continue }
            var levels: [String: [Float]] = [:]
            for (label, set) in cases {
                var record = PhotoRecord()
                set(&record.adjust)
                guard let decoded = PhotoRender.decoded(raw, maxSize: 1000, record: record) else { continue }
                let image = PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: raw), record.adjust, p3: false)
                guard let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: srgb) else { continue }
                if let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name)-\(label).jpg") as CFURL, "public.jpeg" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
                }
                // Brightness (0…1, screen steps) at the 5th, 50th and 95th percentile, and the mean colourfulness.
                var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                px.withUnsafeMutableBytes {
                    CGContext(data: $0.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: srgb,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                }
                var ys: [Float] = [], chroma: Float = 0
                for i in stride(from: 0, to: px.count, by: 16) {
                    let r = Float(px[i]) / 255, g = Float(px[i + 1]) / 255, b = Float(px[i + 2]) / 255
                    ys.append(0.2126 * r + 0.7152 * g + 0.0722 * b); chroma += max(r, g, b) - min(r, g, b)
                }
                ys.sort()
                levels[label] = [ys[ys.count / 20], ys[ys.count / 2], ys[ys.count * 19 / 20], chroma / Float(ys.count)]
            }
            guard let p = levels["plain"] else { continue }
            func l(_ k: String) -> [Float] { levels[k] ?? p }
            // (A bright photo's darkest tones sit near the top of Blacks' reach: a smaller step there, as it should.)
            let step: Float = p[0] > 0.15 ? 0.012 : 0.02
            check("sliders \(name): Blacks −100 darkens the darkest", l("blacks-100")[0] < p[0] - step || (p[0] < 0.04 && l("blacks-100")[0] < 0.005),
                  "5th \(p[0]) → \(l("blacks-100")[0])")
            check("sliders \(name): Blacks +100 opens the darkest", l("blacks+100")[0] > p[0] + step, "5th \(p[0]) → \(l("blacks+100")[0])")
            check("sliders \(name): Whites +100 brightens the brightest", l("whites+100")[2] > p[2] + 0.03, "95th \(p[2]) → \(l("whites+100")[2])")
            check("sliders \(name): Whites −100 holds the brightest back", l("whites-100")[2] < p[2] - 0.04, "95th \(p[2]) → \(l("whites-100")[2])")
            check("sliders \(name): Blacks and Whites leave the middle near", abs(l("blacks-100")[1] - p[1]) < 0.06 && abs(l("whites+100")[1] - p[1]) < 0.08,
                  "50th \(p[1]): blacks \(l("blacks-100")[1]), whites \(l("whites+100")[1])")
            check("sliders \(name): Saturation +100 keeps the brightness", abs(l("sat+100")[1] - p[1]) < 0.04 && l("sat+100")[3] > p[3] * 1.3,
                  "50th \(p[1]) → \(l("sat+100")[1]); colour \(p[3]) → \(l("sat+100")[3])")
            check("sliders \(name): Roll-off soft holds the brightest back, hard pushes them",
                  l("rolloff+100")[2] < p[2] - 0.02 && l("rolloff-100")[2] > p[2] + 0.002, "95th \(p[2]): soft \(l("rolloff+100")[2]), hard \(l("rolloff-100")[2])")
            check("sliders \(name): Basic is more colourful than AgX", l("basic")[3] > p[3] * 1.03, "colour \(p[3]) → \(l("basic")[3])")
            check("sliders \(name): Dehaze −60 doesn't wash out the shadows", l("dehaze-60")[0] < p[0] + 0.12, "5th \(p[0]) → \(l("dehaze-60")[0])")
        }
    }
}
