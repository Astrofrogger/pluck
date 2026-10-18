import CoreImage
import CoreML
import CryptoKit
import Foundation
import Vision

/// How far each place in a photo is (Depth Anything V2 Small, Apple's Core ML version; Apache-2.0),
/// for the Depth Range and Sky masks. An optional download (about 50 MB), checked as it comes
/// in and kept in Pluck's folder; it runs on this Mac.
@MainActor
@Observable
final class PhotoDepth {
    static let shared = PhotoDepth()

    enum State: Equatable { case notInstalled, downloading(Double), ready, failed(String) }
    private(set) var state = State.notInstalled
    nonisolated(unsafe) private static var model: VNCoreMLModel?

    static let downloadMB = 50
    /// The files, pinned to one revision of Apple's model, with their checksums.
    private static let revision = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
    private static let files: [(path: String, sha256: String, size: Int)] = [
        ("Manifest.json", "2883ae290c48fe916dc5ececac03a7d847fa277165a49ef5652fa1d2b9cb55f7", 617),
        ("Data/com.apple.CoreML/model.mlmodel", "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042", 399_433),
        ("Data/com.apple.CoreML/weights/weight.bin", "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed", 49_419_072),
    ]

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Models", isDirectory: true)
    }
    nonisolated private static var compiled: URL { folder.appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc") }

    private init() {
        if Self.isReady { state = .ready }
    }

    /// Whether the depth finder is here (from anywhere).
    nonisolated static var isReady: Bool { FileManager.default.fileExists(atPath: compiled.path) }

    /// Downloads, checks and compiles the model.
    func install() {
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                let package = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-depth-\(UUID().uuidString).mlpackage")
                defer { try? FileManager.default.removeItem(at: package) }
                let total = Double(Self.files.reduce(0) { $0 + $1.size })
                var done = 0.0
                for file in Self.files {
                    let source = URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/\(Self.revision)/DepthAnythingV2SmallF16.mlpackage/\(file.path)")!
                    let (download, _) = try await URLSession.shared.download(from: source)
                    let data = try Data(contentsOf: download, options: .mappedIfSafe)
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard digest == file.sha256 else {
                        throw NSError(domain: "Pluck", code: 30, userInfo: [NSLocalizedDescriptionKey: String(localized: "The download didn’t check out. Try again.")])
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
        Self.model = nil
        state = .notInstalled
    }

    nonisolated private static func loaded() -> VNCoreMLModel? {
        if let model { return model }
        guard FileManager.default.fileExists(atPath: compiled.path), let ml = try? MLModel(contentsOf: compiled),
              let vision = try? VNCoreMLModel(for: ml) else { return nil }
        model = vision
        return vision
    }

    // MARK: - Depth

    nonisolated(unsafe) private static var maps: [String: CIImage] = [:]
    nonisolated private static let lock = NSLock()

    /// How near each place is (1 nearest … 0 farthest), small, for this photo; nil without the model.
    nonisolated static func nearness(_ path: String, from image: CIImage, context: CIContext) -> CIImage? {
        if let known = lock.withLock({ maps[path] }) { return known }
        guard let model = loaded() else { return nil }
        let scale = min(1, 1024 / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent.integral, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let buffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer else { return nil }
        // The model's own scale, made 0 (farthest) to 1 (nearest) for this photo.
        // (Numbers, not colours: no colour space, so nothing converts them.)
        var depth = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let e = depth.extent
        let range = depth.applyingFilter("CIAreaMinMax", parameters: [kCIInputExtentKey: CIVector(cgRect: e)])
        var pixels = [Float](repeating: 0, count: 8)
        context.render(range, toBitmap: &pixels, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 2, height: 1), format: .RGBAf, colorSpace: nil)
        let low = CGFloat(pixels[0]), high = CGFloat(max(pixels[4], pixels[0] + 1e-4))
        depth = depth.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / (high - low), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1 / (high - low), y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1 / (high - low), y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: -low / (high - low), y: -low / (high - low), z: -low / (high - low), w: 0),
        ]).applyingFilter("CIColorClamp")
            // The model gives nearness as disparity, which crowds everything far off into the last
            // few percent: a square root spreads the distance out (far-off things apart from the sky).
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
        // Back to the photo's shape (the model squeezes it into its own).
        let fitted = depth.transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / e.width, y: CGFloat(cg.height) / e.height))
        var values = [Float](repeating: 0, count: cg.width * cg.height)
        context.render(fitted, toBitmap: &values, rowBytes: cg.width * 4, bounds: CGRect(x: 0, y: 0, width: cg.width, height: cg.height),
                       format: .Lf, colorSpace: nil)
        let map = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: cg.width * 4,
                          size: CGSize(width: cg.width, height: cg.height), format: .Lf, colorSpace: nil)
        lock.withLock {
            maps[path] = map
            if maps.count > 16 { maps.removeValue(forKey: maps.keys.first!) }
        }
        return map
    }
}
