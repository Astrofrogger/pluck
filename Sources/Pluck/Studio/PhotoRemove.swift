import CoreImage
import CoreML
import CryptoKit
import Foundation

/// AI Remove: a painted area filled in from the photo around it (LaMa, resolution-robust large mask inpainting; Apache-2.0,
/// a Core ML conversion of advimman/lama). An optional download (about 216 MB), checked as it comes in and kept in Pluck's
/// folder; it runs on this Mac. Used by the Heal tab's Remove spots (PhotoHeal.apply).
@MainActor
@Observable
final class PhotoRemove {
    static let shared = PhotoRemove()

    enum State: Equatable { case notInstalled, downloading(Double), ready, failed(String) }
    private(set) var state = State.notInstalled

    static let downloadMB = 216
    /// The files, pinned to one revision of the conversion, with their checksums.
    private static let repository = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/5ed76e3799ab4cad31381750d29880c267477e18/LaMa.mlpackage/"
    private static let files: [(path: String, sha256: String, size: Int)] = [
        ("Manifest.json", "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58", 617),
        ("Data/com.apple.CoreML/model.mlmodel", "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953", 1_101_809),
        ("Data/com.apple.CoreML/weights/weight.bin", "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184", 215_544_960),
    ]
    /// The model's square (pixels).
    nonisolated static let side = 800

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Models", isDirectory: true)
    }
    nonisolated private static var compiled: URL { folder.appendingPathComponent("LaMa.mlmodelc") }

    private init() {
        if Self.isReady { state = .ready }
    }

    nonisolated static var isReady: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    /// Downloads, checks and compiles the model.
    func install() {
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                let package = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-remove-\(UUID().uuidString).mlpackage")
                defer { try? FileManager.default.removeItem(at: package) }
                let total = Double(Self.files.reduce(0) { $0 + $1.size })
                var done = 0.0
                for file in Self.files {
                    let (download, _) = try await URLSession.shared.download(from: URL(string: Self.repository + file.path)!)
                    let data = try Data(contentsOf: download, options: .mappedIfSafe)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == file.sha256 else {
                        throw NSError(domain: "Pluck", code: 31, userInfo: [NSLocalizedDescriptionKey: String(localized: "The download didn’t check out. Try again.")])
                    }
                    let target = package.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: download, to: target)
                    done += Double(file.size)
                    state = .downloading(done / total)
                }
                let made = try await MLModel.compileModel(at: package)
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: Self.compiled)
                try FileManager.default.moveItem(at: made, to: Self.compiled)
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.compiled)
        Self.lock.withLock { Self.model = nil; Self.fills.removeAll() }
        state = .notInstalled
    }

    // MARK: - Filling

    nonisolated(unsafe) private static var model: MLModel?
    /// Why the last fill wasn't made (for the self-test and the log).
    nonisolated(unsafe) static var problem: String?
    /// Fills made, by what went in (the square's pixels and mask): the same area on the same picture isn't worked out twice.
    nonisolated(unsafe) private static var fills: [String: CVPixelBuffer] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    /// One fill at a time (the model is large; a second at once would only wait for memory).
    nonisolated private static let lock = NSLock()

    /// Light to the model's picture and back: a soft roll-off (1.25·x/(1+x)) keeps a little room above white, so a fill on a
    /// bright sky isn't clipped grey when the exposure comes down.
    nonisolated(unsafe) private static let squeeze = CIColorKernel(source: "kernel vec4 squeeze(__sample c) { vec3 v = max(c.rgb, 0.0); return vec4(1.25 * v / (1.0 + v), 1.0); }")
    nonisolated(unsafe) private static let unsqueeze = CIColorKernel(source: "kernel vec4 unsqueeze(__sample c) { vec3 v = min(c.rgb, 1.2); return vec4(v / (1.25 - v), 1.0); }")

    /// The area `mask` (white: fill) of `image` filled in, within `square` (the part of the photo the model sees, made
    /// 800 × 800). Nil without the model or if it fails; the fill covers `square` only.
    nonisolated static func fill(_ image: CIImage, mask: CIImage, square: CGRect, context: CIContext) -> CIImage? {
        guard isReady, let squeeze, let unsqueeze else { problem = "no model or kernels"; return nil }
        let n = side, scale = CGFloat(n) / square.width
        // (Moved, then scaled: `scaledBy` would scale first, which only came out right near a scale of 1.)
        let place = CGAffineTransform(translationX: -square.minX, y: -square.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        // The area brought to an everyday brightness first (a RAW's decode is scene light, often 3 stops under: the model
        // then saw a near-black picture and filled it poorly), and back after.
        var average = [Float](repeating: 0, count: 4)
        context.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: square)]), toBitmap: &average,
                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let Y = max(0.2126 * average[0] + 0.7152 * average[1] + 0.0722 * average[2], 1e-5)
        let gain = CGFloat(min(max(0.2 / Y, 0.25), 32))
        func scaled(_ i: CIImage, _ k: CGFloat) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                                                           "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)])
        }
        let picture = squeeze.apply(extent: image.extent, arguments: [scaled(image.clampedToExtent(), gain)])?.transformed(by: place)
            .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        let hole = mask.transformed(by: place).cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
        guard let picture, let input = buffer(picture, kCVPixelFormatType_32BGRA, context: context, colour: true),
              let holeBuffer = buffer(hole, kCVPixelFormatType_OneComponent8, context: context, colour: false) else { problem = "input not drawn: \(problem ?? "")"; return nil }
        let key = digest(input) + digest(holeBuffer)
        let made: CVPixelBuffer? = lock.withLock {
            if let known = fills[key] { return known }
            if model == nil {
                let config = MLModelConfiguration()
                config.computeUnits = .all // (as the conversion was checked)
                model = try? MLModel(contentsOf: compiled, configuration: config)
                // (The first fill after loading came back black: one made and thrown away first.)
                _ = model.flatMap { try? $0.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: input), "mask": MLFeatureValue(pixelBuffer: holeBuffer)])) }
            }
            guard let model else { problem = "model didn't load"; return nil }
            // A fill that comes back black where the picture isn't is made again (and never kept).
            var made: CVPixelBuffer?
            for _ in 0..<3 {
                guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "image": MLFeatureValue(pixelBuffer: input), "mask": MLFeatureValue(pixelBuffer: holeBuffer),
                ])) else { problem = "prediction failed"; return nil }
                guard let given = result.featureValue(for: "output")?.imageBufferValue else { problem = "no output"; return nil }
                guard let out = copy(given) else { problem = "copy failed (\(CVPixelBufferGetPixelFormatType(given)))"; return nil }
                if level(out) > 0.2 * level(input) || level(input) < 2 { made = out; break }
                problem = "black output: \(level(out)) against \(level(input))"
            }
            guard let out = made else { return nil }
            problem = nil
            fills[key] = out
            order.append(key)
            if order.count > 24 { fills.removeValue(forKey: order.removeFirst()) }
            return out
        }
        guard let made else { return nil }
        let back = CIImage(cvPixelBuffer: made, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return unsqueeze.apply(extent: back.extent, arguments: [back]).map { scaled($0, 1 / gain).transformed(by: place.inverted()) }
    }

    nonisolated private static func buffer(_ image: CIImage, _ format: OSType, context: CIContext, colour: Bool) -> CVPixelBuffer? {
        // (Drawn as a picture first, then copied in on the CPU: drawing a RAW's decode straight into the model's buffer on the
        // GPU failed or came back black.)
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        // (The mask too in colour: a grey one wasn't made. Black and white come through the same.)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let picture = context.createCGImage(image, from: frame, format: .RGBA8, colorSpace: space) else {
            problem = "createCGImage \(colour)"; return nil
        }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let base = CVPixelBufferGetBaseAddress(made),
              let drawing = CGContext(data: base, width: side, height: side, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(made),
                                      space: colour ? space : CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: colour ? CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                                                         : CGImageAlphaInfo.none.rawValue) else {
            problem = "CGContext \(colour) \(CVPixelBufferGetBytesPerRow(made))"; return nil
        }
        drawing.interpolationQuality = .none
        drawing.draw(picture, in: frame)
        return made
    }

    /// The model's output copied into a buffer of Pluck's own: Core ML hands out its buffers again for the next fill, which
    /// turned earlier fills (still being drawn from) black.
    nonisolated private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source), format = CVPixelBufferGetPixelFormatType(source)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly); CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly); CVPixelBufferUnlockBaseAddress(made, []) }
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(made) else { return nil }
        let rowIn = CVPixelBufferGetBytesPerRow(source), rowOut = CVPixelBufferGetBytesPerRow(made)
        for y in 0..<h { memcpy(to + y * rowOut, from + y * rowIn, min(rowIn, rowOut)) }
        return made
    }

    /// A BGRA buffer's average brightness (0…255), from every 16th pixel.
    nonisolated private static func level(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let row = CVPixelBufferGetBytesPerRow(buffer), w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
            let p = base + y * row + x * 4
            sum += Double(p[0]) + Double(p[1]) + Double(p[2]); n += 3
        } }
        return n > 0 ? sum / n : 0
    }

    nonisolated private static func digest(_ buffer: CVPixelBuffer) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return UUID().uuidString }
        let data = Data(bytesNoCopy: base, count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer), deallocator: .none)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
