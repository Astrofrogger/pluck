import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What Pluck measures in a photo to group and rank it: how sharp it is (overall and on the
/// faces), the faces and their eyes, Apple's aesthetics score, whether softness runs in one
/// direction, and a feature print to tell similar frames. Always measured on the normalised
/// picture (grey, its brightness evened out), so an edited preview and the camera's own give the
/// same numbers, and a style learned in Lightroom works on new shoots.
struct PhotoSignals: Codable, Hashable {
    /// Fine detail: the 90th percentile of the Laplacian's variance over a 6 × 6 grid of tiles.
    var sharpness: Double?
    /// The same on the biggest face, when there is one.
    var faceSharpness: Double?
    var faceCount = 0
    /// The biggest face's share of the picture (0 with none).
    var faceSize = 0.0
    /// Vision's capture quality of the biggest face (0…1).
    var faceQuality: Double?
    /// How open the biggest face's eyes are: the less open eye's height over its width.
    var eyesOpen: Double?
    /// Apple's overall aesthetics score (−1…1, macOS 15 and later).
    var aesthetics: Double?
    /// Whether Apple sees it as a utility picture (a screenshot, a receipt…; macOS 15 and later).
    var utility: Bool?
    /// 0 when the picture is evenly soft or sharp, 1 when its detail streaks in one direction (motion).
    var blurDirection = 0.0
    /// Vision's feature print (revision 2): close prints, similar pictures.
    var print: [Float] = []
    /// Exposure time in seconds, ISO and focal length, from the EXIF when there is one.
    var shutter: Double?
    var iso: Double?
    var focal: Double?

    /// Pictures are measured at most this big on their long side (the Lightroom previews are 750).
    nonisolated static let workSize = 768

    // MARK: - Normalising

    /// A grey picture as numbers from 0 to 1, row by row from the top.
    private struct Gray {
        var width: Int
        var height: Int
        var pixels: [Float]
    }

    /// The picture as Pluck measures it: grey, at most `workSize` on its long side, stretched so
    /// its 1st and 99th percentiles are black and white, with a gamma that puts its median at
    /// 0.45. Nothing of the edit's brightness, contrast or colour is left to learn from.
    nonisolated static func normalised(_ image: CGImage) -> CGImage {
        let gray = normalisedGray(image)
        return cgImage(gray) ?? image
    }

    nonisolated private static func normalisedGray(_ image: CGImage) -> Gray {
        let scale = min(1, Double(workSize) / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.interpolationQuality = .high
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var gray = [Float](repeating: 0, count: width * height)
        for i in 0..<gray.count {
            gray[i] = (0.2126 * Float(rgba[i * 4]) + 0.7152 * Float(rgba[i * 4 + 1]) + 0.0722 * Float(rgba[i * 4 + 2])) / 255
        }
        let sample = stride(from: 0, to: gray.count, by: 7).map { gray[$0] }
        let low = percentile(sample, 0.01), high = percentile(sample, 0.99)
        let span = max(high - low, 0.02)
        let median = min(max(percentile(sample.map { min(1, max(0, ($0 - low) / span)) }, 0.5), 0.02), 0.98)
        let gamma = log(Float(0.45)) / log(median)
        for i in 0..<gray.count { gray[i] = pow(min(1, max(0, (gray[i] - low) / span)), gamma) }
        return Gray(width: width, height: height, pixels: gray)
    }

    nonisolated private static func cgImage(_ gray: Gray) -> CGImage? {
        let bytes = gray.pixels.map { UInt8(max(0, min(255, $0 * 255 + 0.5))) }
        guard let data = CFDataCreate(nil, bytes, bytes.count), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: gray.width, height: gray.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: gray.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Measuring

    /// Normalises the picture, then measures it. `exif` is the photo's EXIF dictionary, or its
    /// whole set of properties (the EXIF is taken from inside).
    nonisolated static func measure(_ image: CGImage, exif: [CFString: Any]?) -> PhotoSignals {
        let gray = normalisedGray(image)
        var signals = PhotoSignals()
        let w = gray.width, h = gray.height

        // Sharpness and the direction of the detail, on a 6 × 6 grid.
        var tiles: [Float] = []
        for ty in 0..<6 {
            for tx in 0..<6 {
                tiles.append(laplacianVariance(gray, CGRect(x: tx * w / 6, y: ty * h / 6, width: (tx + 1) * w / 6 - tx * w / 6,
                                                            height: (ty + 1) * h / 6 - ty * h / 6)))
            }
        }
        signals.sharpness = Double(percentile(tiles, 0.9))
        signals.blurDirection = coherence(tensor(gray, CGRect(x: 0, y: 0, width: w, height: h)))

        // Faces, aesthetics and the feature print, from Vision on the normalised picture.
        guard let picture = cgImage(gray) else { return signals.with(exif: exif) }
        let handler = VNImageRequestHandler(cgImage: picture, options: [:])
        let landmarks = VNDetectFaceLandmarksRequest()
        let print = VNGenerateImageFeaturePrintRequest()
        print.revision = VNGenerateImageFeaturePrintRequestRevision2
        var requests: [VNRequest] = [landmarks, print]
        var aesthetics: VNRequest?
        if #available(macOS 15, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            aesthetics = request
            requests.append(request)
        }
        try? handler.perform(requests)
        if #available(macOS 15, *), let score = (aesthetics as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
            signals.aesthetics = Double(score.overallScore)
            signals.utility = score.isUtility
        }
        if let observation = print.results?.first {
            signals.print = floats(observation.data)
        }

        let faces = (landmarks.results ?? []).filter { $0.boundingBox.width > 0.04 }
        signals.faceCount = faces.count
        if let biggest = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
            let box = biggest.boundingBox
            signals.faceSize = Double(box.width * box.height)
            signals.faceSharpness = Double(laplacianVariance(gray, CGRect(x: box.minX * CGFloat(w), y: (1 - box.maxY) * CGFloat(h),
                                                                          width: box.width * CGFloat(w), height: box.height * CGFloat(h))))
            if let left = biggest.landmarks?.leftEye, let right = biggest.landmarks?.rightEye {
                signals.eyesOpen = min(PhotoChecks.openness(left), PhotoChecks.openness(right))
            }
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = [biggest]
            try? handler.perform([quality])
            signals.faceQuality = quality.results?.first?.faceCaptureQuality.map(Double.init)
        }
        return signals.with(exif: exif)
    }

    /// How far apart two feature prints are (straight-line distance; about 0.45 is still one moment).
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        vDSP_distancesq(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum.squareRoot()
    }

    /// Raw bytes as numbers (copied, so the bytes needn't be aligned).
    nonisolated private static func floats(_ data: Data) -> [Float] {
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    private func with(exif: [CFString: Any]?) -> PhotoSignals {
        guard let exif else { return self }
        let values = exif[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? exif
        var signals = self
        signals.shutter = (values[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        signals.iso = ((values[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first)?.doubleValue
        signals.focal = (values[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
        return signals
    }

    // MARK: - Measures

    nonisolated private static func percentile(_ values: [Float], _ q: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * q)))]
    }

    /// The variance of the Laplacian (how strong the finest edges are) inside `area`, in pixels from the top left.
    nonisolated private static func laplacianVariance(_ g: Gray, _ area: CGRect) -> Float {
        let w = g.width
        let xa = max(1, Int(area.minX)), xb = min(g.width - 1, Int(area.maxX)), ya = max(1, Int(area.minY)), yb = min(g.height - 1, Int(area.maxY))
        guard xb > xa, yb > ya else { return 0 }
        var sum = 0.0, squares = 0.0
        g.pixels.withUnsafeBufferPointer { p in
            for y in ya..<yb {
                for x in xa..<xb {
                    let i = y * w + x
                    let l = Double(p[i - 1] + p[i + 1] + p[i - w] + p[i + w] - 4 * p[i])
                    sum += l
                    squares += l * l
                }
            }
        }
        let n = Double((xb - xa) * (yb - ya)), mean = sum / n
        return Float(squares / n - mean * mean)
    }

    /// The structure tensor's sums inside `area`: gx², gy² and gx·gy.
    nonisolated private static func tensor(_ g: Gray, _ area: CGRect) -> (xx: Double, yy: Double, xy: Double) {
        let w = g.width
        let xa = max(1, Int(area.minX)), xb = min(g.width - 1, Int(area.maxX)), ya = max(1, Int(area.minY)), yb = min(g.height - 1, Int(area.maxY))
        guard xb > xa, yb > ya else { return (0, 0, 0) }
        var xx = 0.0, yy = 0.0, xy = 0.0
        g.pixels.withUnsafeBufferPointer { p in
            for y in ya..<yb {
                for x in xa..<xb {
                    let i = y * w + x
                    let gx = Double(p[i + 1] - p[i - 1]), gy = Double(p[i + w] - p[i - w])
                    xx += gx * gx
                    yy += gy * gy
                    xy += gx * gy
                }
            }
        }
        return (xx, yy, xy)
    }

    /// How much the edges agree on one direction: 0 when they go every way, 1 when they all line up.
    nonisolated private static func coherence(_ t: (xx: Double, yy: Double, xy: Double)) -> Double {
        let trace = t.xx + t.yy
        guard trace > 1e-12 else { return 0 }
        return ((t.xx - t.yy) * (t.xx - t.yy) + 4 * t.xy * t.xy).squareRoot() / trace
    }

    // MARK: - Saving

    private enum CodingKeys: String, CodingKey {
        case sharpness, faceSharpness, faceCount, faceSize, faceQuality, eyesOpen, aesthetics, utility, blurDirection, print, shutter, iso, focal
    }

    init() {}

    /// The feature print is saved as raw bytes (base64 in JSON), a quarter of the size of a list of numbers.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness)
        faceSharpness = try c.decodeIfPresent(Double.self, forKey: .faceSharpness)
        faceCount = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        faceSize = try c.decodeIfPresent(Double.self, forKey: .faceSize) ?? 0
        faceQuality = try c.decodeIfPresent(Double.self, forKey: .faceQuality)
        eyesOpen = try c.decodeIfPresent(Double.self, forKey: .eyesOpen)
        aesthetics = try c.decodeIfPresent(Double.self, forKey: .aesthetics)
        utility = try c.decodeIfPresent(Bool.self, forKey: .utility)
        blurDirection = try c.decodeIfPresent(Double.self, forKey: .blurDirection) ?? 0
        let data = try c.decodeIfPresent(Data.self, forKey: .print) ?? Data()
        print = Self.floats(data)
        shutter = try c.decodeIfPresent(Double.self, forKey: .shutter)
        iso = try c.decodeIfPresent(Double.self, forKey: .iso)
        focal = try c.decodeIfPresent(Double.self, forKey: .focal)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sharpness, forKey: .sharpness)
        try c.encodeIfPresent(faceSharpness, forKey: .faceSharpness)
        try c.encode(faceCount, forKey: .faceCount)
        try c.encode(faceSize, forKey: .faceSize)
        try c.encodeIfPresent(faceQuality, forKey: .faceQuality)
        try c.encodeIfPresent(eyesOpen, forKey: .eyesOpen)
        try c.encodeIfPresent(aesthetics, forKey: .aesthetics)
        try c.encodeIfPresent(utility, forKey: .utility)
        try c.encode(blurDirection, forKey: .blurDirection)
        try c.encode(print.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .print)
        try c.encodeIfPresent(shutter, forKey: .shutter)
        try c.encodeIfPresent(iso, forKey: .iso)
        try c.encodeIfPresent(focal, forKey: .focal)
    }
}
