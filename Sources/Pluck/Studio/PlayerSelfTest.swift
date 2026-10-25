import AppKit
import CoreGraphics

/// Tests for the Raw Player (screenshot mode "playertest"): each check is a line in
/// -PluckScreenshotLog <file>, "PASS name" or "FAIL name: detail", then "done".
@MainActor
enum PlayerSelfTest {
    private static var lines: [String] = []
    private static var log = ""

    static func run(defaults: UserDefaults) async {
        guard let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        log = logPath
        lines = []
        await scopes()
        falseColour()
        compare()
        lines.append("done")
        write()
        NSApp.terminate(nil)
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        lines.append(ok ? "PASS \(name)" : "FAIL \(name): \(detail())")
        write()
    }

    private static func write() { try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8) }

    /// A flat picture of one Rec.709 colour (components 0...1).
    static func flat(_ r: Double, _ g: Double, _ b: Double, size: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    /// The middle pixel of an image, as 8-bit RGB.
    private static func centre(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// The compare layer drawn into an image, and the pixel at a fraction of its width (half way down).
    private static func render(_ layer: ComparePictureLayer, size: Int) -> (CGFloat) -> (r: Int, g: Int, b: Int) {
        layer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        layer.layoutIfNeeded()
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.render(in: context)
        return { fraction in
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            let offset = (size / 2 * size + Int(fraction * CGFloat(size))) * 4
            return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
        }
    }

    private static func compare() {
        let layer = ComparePictureLayer()
        layer.setA(flat(1, 0, 0))
        layer.setCompare(mode: .split, b: flat(0, 0, 1), splitAt: 0.5)
        var pixel = render(layer, size: 200)
        var left = pixel(0.25), right = pixel(0.75)
        check("split shows B left", left.b > 200 && left.r < 60 && right.r > 200 && right.b < 60, "left \(left) right \(right)")

        layer.setCompare(mode: .split, b: flat(0, 0, 1), splitAt: 0.25)
        pixel = render(layer, size: 200)
        left = pixel(0.1); right = pixel(0.4)
        check("split follows the line", left.b > 200 && right.r > 200, "left \(left) right \(right)")

        layer.setCompare(mode: .sideBySide, b: flat(0, 0, 1), splitAt: 0.5)
        pixel = render(layer, size: 200)
        left = pixel(0.25); right = pixel(0.75)
        check("side by side shows both", left.b > 200 && left.r < 60 && right.r > 200 && right.b < 60, "left \(left) right \(right)")

        layer.setCompare(mode: .off, b: flat(0, 0, 1), splitAt: 0.5)
        pixel = render(layer, size: 200)
        left = pixel(0.25)
        check("compare off shows only A", left.r > 200 && left.b < 60, "left \(left)")

        // B of another shape lines up with A's picture: a 16:9 A in a square view, B fitted into where A is.
        let view = CGSize(width: 200, height: 200)
        let wide = CGSize(width: 1920, height: 1080)
        let split = CompareLayout.rects(mode: .split, splitAt: 0.5, size: view, aPicture: wide)
        let picture = CompareLayout.fit(wide, in: CGRect(origin: .zero, size: view))
        check("compare fits B into A's picture", split.b == picture && abs(picture.height - 112.5) < 0.01 && abs(picture.midY - 100) < 0.01, "b \(split.b)")
        check("compare split keeps the whole height visible", split.bVisible.height == view.height && split.bVisible.width == 100, "visible \(split.bVisible)")
        let beside = CompareLayout.rects(mode: .sideBySide, splitAt: 0.5, size: view, aPicture: wide)
        check("compare side by side gives B A's size", abs(beside.b.width - 100) < 0.01 && abs(beside.b.height - 56.25) < 0.01 && abs(beside.b.midY - 100) < 0.01, "b \(beside.b)")
        let unknown = CompareLayout.rects(mode: .split, splitAt: 0.5, size: view)
        check("compare without A's size fills the view", unknown.b == CGRect(origin: .zero, size: view))

        // Same timecode when it is inside the other clip, else the same offset.
        let inside = RawPlayer.matchingFrame(index: 10, startTimecode: "01:00:00:00", otherTimecode: "01:00:00:05", otherFrames: 100, rate: 24)
        check("compare uses the same timecode", inside == 5, "frame \(inside)")
        let outside = RawPlayer.matchingFrame(index: 10, startTimecode: "01:00:00:00", otherTimecode: "02:00:00:00", otherFrames: 100, rate: 24)
        check("compare falls back to the same offset", outside == 10, "frame \(outside)")
        let clamped = RawPlayer.matchingFrame(index: 50, startTimecode: nil, otherTimecode: nil, otherFrames: 20, rate: 24)
        check("compare offset stays in the clip", clamped == 19, "frame \(clamped)")
    }

    private static func falseColour() {
        let clipped = centre(FalseColour.apply(flat(1, 1, 1)))
        check("false colour clipped is red", clipped.r > 200 && clipped.g < 60 && clipped.b < 60, "rgb \(clipped)")
        // 42 IRE: 0.42 of full range, in the 18 % grey band.
        let mid = centre(FalseColour.apply(flat(0.42, 0.42, 0.42)))
        check("false colour mid grey is green", mid.g > mid.r + 60 && mid.g > mid.b + 60, "rgb \(mid)")
        // Band edges are crisp: 99.5 IRE is already the clipped red (not blended with the yellow below),
        // and 37 IRE, just under the 38 band, is no green at all.
        let edge = centre(FalseColour.apply(flat(0.995, 0.995, 0.995)))
        check("false colour 99.5 IRE is red", edge.r > 200 && edge.g < 60 && edge.b < 60, "rgb \(edge)")
        let below = centre(FalseColour.apply(flat(0.37, 0.37, 0.37)))
        check("false colour 37 IRE is not green", !(below.g > below.r + 20 && below.g > below.b + 20), "rgb \(below)")
        let above = centre(FalseColour.apply(flat(0.385, 0.385, 0.385)))
        check("false colour 38.5 IRE is green", above.g > above.r + 60 && above.g > above.b + 60, "rgb \(above)")
    }

    private static func scopes() async {
        let analyzer = ScopeAnalyzer()

        let grey = await analyzer.analyze(flat(0.5, 0.5, 0.5))
        let peaks = (0..<grey.width).map { ScopeAnalyzer.peak(grey.luma, column: $0) }
        check("waveform of grey", peaks.allSatisfy { $0 == 127 || $0 == 128 }, "peaks \(Set(peaks).sorted())")

        let red = await analyzer.analyze(flat(1, 0, 0))
        let r = ScopeAnalyzer.peak(red.red, column: 10), g = ScopeAnalyzer.peak(red.green, column: 10), b = ScopeAnalyzer.peak(red.blue, column: 10)
        check("parade of red", r == 255 && g == 0 && b == 0, "r \(r) g \(g) b \(b)")

        func peakBin(_ data: ScopeData) -> (cb: Int, cr: Int) {
            var best = 0
            for i in data.vector.indices where data.vector[i] > data.vector[best] { best = i }
            return (best % 256, best / 256)
        }
        let centre = peakBin(grey)
        check("vectorscope of grey is centre", centre.cb == 128 && centre.cr == 128, "peak \(centre)")

        let target = ScopeAnalyzer.vectorPoint(red: 0.75, green: 0, blue: 0)
        let seen = peakBin(await analyzer.analyze(flat(0.75, 0, 0)))
        check("vectorscope of 75% red", abs(Double(seen.cb) - target.cb) <= 4 && abs(Double(seen.cr) - target.cr) <= 4,
              "peak \(seen), target \(Int(target.cb)), \(Int(target.cr))")

        // Not part of the plan's four: nothing is analysed while off; a hidden panel costs nothing.
        let feed = ScopeFeed()
        feed.offer(flat(0.5, 0.5, 0.5), playing: true)
        try? await Task.sleep(for: .milliseconds(200))
        check("scopes off analyse nothing", feed.analysed == 0 && feed.data == nil)
        feed.enabled = true
        var offered = 0
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 1 { feed.offer(flat(0.5, 0.5, 0.5), playing: true); offered += 1; try? await Task.sleep(for: .milliseconds(2)) }
        check("scopes analyse at most 12 a second", feed.analysed > 0 && feed.analysed <= 13, "\(feed.analysed) of \(offered)")
    }
}
