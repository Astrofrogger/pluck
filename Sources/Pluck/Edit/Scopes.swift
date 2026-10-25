import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import Observation

/// Scopes for the raw player: the picture counted into bins by brightness and colour, so a
/// waveform, an RGB parade and a vectorscope can be drawn from it (see ScopesView).

enum ScopeKind: String, CaseIterable, Identifiable {
    case waveform, parade, vectorscope
    var id: String { rawValue }
    var label: String {
        switch self {
        case .waveform: String(localized: "Waveform")
        case .parade: String(localized: "Parade")
        case .vectorscope: String(localized: "Vectorscope")
        }
    }
}

/// One analysed frame. The waveform arrays are `width × 256` bins (index `column * 256 + code value`);
/// `vector` is 256 × 256 (index `Cr * 256 + Cb`, 128 and 128 is no colour). Counts stop at 65535.
struct ScopeData: Sendable {
    var width: Int
    var luma: [UInt16]
    var red: [UInt16]
    var green: [UInt16]
    var blue: [UInt16]
    var vector: [UInt16]
}

/// Counts a frame into ScopeData, from a small copy of it in Rec.709 code values.
actor ScopeAnalyzer {
    func analyze(_ image: CGImage, columns: Int = 360) -> ScopeData {
        Self.analyzed(image, columns: columns)
    }

    nonisolated static func analyzed(_ image: CGImage, columns: Int = 360) -> ScopeData {
        let width = max(1, min(columns, image.width))
        let height = max(1, min(Int((Double(image.height) / Double(image.width) * Double(width)).rounded()), 2 * width))
        var data = ScopeData(width: width, luma: [UInt16](repeating: 0, count: width * 256),
                             red: [UInt16](repeating: 0, count: width * 256), green: [UInt16](repeating: 0, count: width * 256),
                             blue: [UInt16](repeating: 0, count: width * 256), vector: [UInt16](repeating: 0, count: 256 * 256))
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let base = context.data else { return data }
        // Drawn into the small Rec.709 bitmap: the scaling and the colour conversion in one go. Nearest-neighbour: a sample of the picture is enough for a scope, and it is far cheaper than averaging every pixel while the decoders have the CPU.
        context.interpolationQuality = .none
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Shrunk in the picture's own colour space first (no colour matching of a 6K frame), then the small copy converted.
        if let own = image.colorSpace, own.model == .rgb, own.name != space.name,
           let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: own,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            small.interpolationQuality = .none
            small.draw(image, in: rect)
            if let shrunk = small.makeImage() { context.draw(shrunk, in: rect) } else { context.draw(image, in: rect) }
        } else {
            context.draw(image, in: rect)
        }
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        data.luma.withUnsafeMutableBufferPointer { luma in
        data.red.withUnsafeMutableBufferPointer { red in
        data.green.withUnsafeMutableBufferPointer { green in
        data.blue.withUnsafeMutableBufferPointer { blue in
        data.vector.withUnsafeMutableBufferPointer { vector in
            @inline(__always) func add(_ bins: UnsafeMutableBufferPointer<UInt16>, _ at: Int) {
                if bins[at] < .max { bins[at] += 1 }
            }
            for y in 0..<height {
                let row = pixels + y * stride
                for x in 0..<width {
                    let r = Float(row[x * 4]), g = Float(row[x * 4 + 1]), b = Float(row[x * 4 + 2])
                    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let cb = (b - luminance) / 1.8556, cr = (r - luminance) / 1.5748
                    add(luma, x * 256 + min(255, Int(luminance.rounded())))
                    add(red, x * 256 + Int(r)); add(green, x * 256 + Int(g)); add(blue, x * 256 + Int(b))
                    add(vector, min(255, max(0, Int((128 + cr).rounded()))) * 256 + min(255, max(0, Int((128 + cb).rounded()))))
                }
            }
        }}}}}
        return data
    }

    /// Where a colour (R'G'B' 0...1, Rec.709) lands on the vectorscope: bins from the left and from the bottom.
    nonisolated static func vectorPoint(red: Double, green: Double, blue: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return (128 + (blue - y) / 1.8556 * 255, 128 + (red - y) / 1.5748 * 255)
    }

    /// The peak bin of a waveform column.
    nonisolated static func peak(_ bins: [UInt16], column: Int) -> Int {
        var best = 0, count: UInt16 = 0
        for code in 0..<256 where bins[column * 256 + code] > count { count = bins[column * 256 + code]; best = code }
        return best
    }
}

/// Hands the player's shown frames to the analyzer: nothing at all while off, at most 12 a second
/// while playing, one at a time, away from the main thread (a frame that arrives meanwhile is dropped
/// while playing; a still waits its turn).
@MainActor
@Observable
final class ScopeFeed {
    private(set) var data: ScopeData?
    /// Off while the panel is hidden: then `offer` returns at once.
    @ObservationIgnored var enabled = false
    /// How many frames were analysed (tests).
    @ObservationIgnored private(set) var analysed = 0
    /// Seconds spent analysing, all frames together (tests).
    @ObservationIgnored private(set) var spent = 0.0
    @ObservationIgnored private let analyzer = ScopeAnalyzer()
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var last = Date.distantPast
    @ObservationIgnored private var waiting: CGImage?
    /// Bumped by `clear`: an analysis under way for a picture from before it is dropped.
    @ObservationIgnored private var epoch = 0
    static let interval = 1.0 / 12

    func offer(_ image: CGImage, playing: Bool) {
        guard enabled else { return }
        if playing {
            // A frame over 3000 px wide costs about 45 ms to shrink, while the decoders have all the cores: half the rate then.
            guard !busy, Date.now.timeIntervalSince(last) >= (image.width > 3000 ? 2 : 1) * Self.interval else { return }
        } else if busy {
            waiting = image
            return
        }
        run(image)
    }

    private func run(_ image: CGImage) {
        busy = true
        last = .now
        let mine = epoch
        Task(priority: .utility) {
            let began = Date.now
            let result = await analyzer.analyze(image)
            spent += Date.now.timeIntervalSince(began)
            busy = false
            guard enabled else { waiting = nil; return }
            if mine == epoch {
                data = result
                analysed += 1
            }
            if let next = waiting { waiting = nil; run(next) }
        }
    }

    func clear() { data = nil; waiting = nil; epoch += 1 }
}

/// False colour: each picture colour shown as the band its brightness falls in (IRE, Rec.709 luma of the
/// full-range code values), so clipping, skin and 18 % grey read at a glance. Anything in no band is the
/// grey of its brightness. The brightness map is built once; a frame goes through it on the GPU.
enum FalseColour {
    /// The bands in IRE (the first that holds a brightness gives its colour).
    static let bands: [(range: ClosedRange<Double>, color: CGColor)] = [
        (0...2.5, colour(0.45, 0, 0.6)),     // crushed: purple
        (2.5...10, colour(0, 0.2, 0.9)),     // shadows: blue
        (10...20, colour(0.3, 0.3, 0.3)),    // low: dark grey
        (38...45, colour(0.1, 0.75, 0.2)),   // 18 % grey: green
        (52...56, colour(1, 0.55, 0.7)),     // skin, one stop over: pink
        (63...68, colour(0.8, 0.8, 0.8)),    // light grey
        (93...99, colour(1, 0.9, 0)),        // near clip: yellow
        (99...100, colour(1, 0, 0)),         // clipped: red
    ]

    /// Steps in the map from brightness to colour (a band's edge is exact to 1/4096 of full range).
    static let mapSize = 4096

    private static func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The band colour (or the grey of its brightness) at a brightness in IRE.
    static func colour(atIRE ire: Double) -> (r: Double, g: Double, b: Double) {
        if let band = bands.first(where: { $0.range.contains(ire) }), let c = band.color.components, c.count >= 3 {
            return (Double(c[0]), Double(c[1]), Double(c[2]))
        }
        let grey = min(max(ire / 100, 0), 1)
        return (grey, grey, grey)
    }

    /// One row of brightness steps from 0 to 100 IRE, each its band's colour (made once). A lookup
    /// in it has crisp edges, which a colour cube between grid points can't give.
    private static let map: CIImage = {
        let n = mapSize
        var bytes = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            let c = colour(atIRE: Double(i) / Double(n - 1) * 100)
            bytes[i * 4] = UInt8((c.r * 255).rounded())
            bytes[i * 4 + 1] = UInt8((c.g * 255).rounded())
            bytes[i * 4 + 2] = UInt8((c.b * 255).rounded())
        }
        let image = bytes.withUnsafeBytes { raw -> CIImage in
            let data = Data(raw)
            return CIImage(bitmapData: data, bytesPerRow: n * 4, size: CGSize(width: n, height: 1), format: .RGBA8, colorSpace: nil)
        }
        return image
    }()

    /// Colour management off: the picture's code values go through the map as they are.
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// The picture in false colour, the same size. The picture itself is returned if the filter can't run.
    static func apply(_ image: CGImage) -> CGImage {
        let input = CIImage(cgImage: image, options: [.colorSpace: NSNull()])
        // Rec.709 luma into every channel, then that brightness looked up in the map.
        let luma = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        guard let filter = CIFilter(name: "CIColorMap") else { return image }
        filter.setValue(luma, forKey: kCIInputImageKey)
        filter.setValue(map, forKey: "inputGradientImage")
        // Out in the picture's own space (a 16-bit RAW frame fails to come out with no space at all).
        guard let output = filter.outputImage,
              let made = context.createCGImage(output, from: input.extent, format: .RGBA8,
                                               colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else { return image }
        return made
    }
}
