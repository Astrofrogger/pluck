import CoreImage
import CoreML
import CryptoKit
import Foundation

/// Click masks before macOS 27 (macOS 27 has its own object finder, see PhotoMasks.findObject): Segment Anything 2.1 small,
/// Apple's Core ML version (apple/coreml-sam2.1-small, Apache-2.0). An optional download (about 94 MB), checked as it comes
/// in and kept in Pluck's folder; it runs on this Mac.
@MainActor
@Observable
final class PhotoSAM {
    static let shared = PhotoSAM()

    enum State: Equatable { case notInstalled, downloading(Double), ready, failed(String) }
    private(set) var state = State.notInstalled

    static let downloadMB = 94
    private static let repository = "https://huggingface.co/apple/coreml-sam2.1-small/resolve/883f5787eb0be35ce6965907a8bc1f5320a5a02e/"
    private static let packages: [(name: String, files: [(path: String, sha256: String, size: Int)])] = [
        ("SAM2_1SmallImageEncoderFLOAT16", [
            ("Manifest.json", "442f9102d1a37c2699fce89b1f5257d35ebd0a7096f1773501cb0aba94fe95b6", 617),
            ("Data/com.apple.CoreML/model.mlmodel", "736602a3130875072f843df123ce3ceff41ec2f917a867da56f7c2264d81a567", 203_631),
            ("Data/com.apple.CoreML/weights/weight.bin", "6128a58f10cbcb7797bd12a7ec1e05ab4e9f8c80bd14ed05bbc43a9c9935a9c3", 81_268_288),
        ]),
        ("SAM2_1SmallPromptEncoderFLOAT16", [
            ("Manifest.json", "b368a8e831599464347890a79c054df143c163d9928e3e0a2ab6ef7c00a425d4", 617),
            ("Data/com.apple.CoreML/model.mlmodel", "3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3", 20_618),
            ("Data/com.apple.CoreML/weights/weight.bin", "e29c6c65ef7754f8f6ed26155ca39ea703de3a7f576be5a7d3b8e29545059f31", 2_101_056),
        ]),
        ("SAM2_1SmallMaskDecoderFLOAT16", [
            ("Manifest.json", "d95d732931f590dbf6a08ea1fe58a6659ced8971c5b2a671d79091be1a63b9e1", 617),
            ("Data/com.apple.CoreML/model.mlmodel", "3536b71674dc706381f42833b55627fd3d1f2c1b68a365b49255284b4f7b55c7", 75_167),
            ("Data/com.apple.CoreML/weights/weight.bin", "dbc4910c434fee657ed9f001da7abcb467d2a37ac235099c6aa47628b122ec4e", 10_222_400),
        ]),
    ]

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Models", isDirectory: true)
    }
    nonisolated private static func compiled(_ name: String) -> URL { folder.appendingPathComponent(name + ".mlmodelc") }

    private init() {
        if Self.isReady { state = .ready }
    }

    nonisolated static var isReady: Bool { packages.allSatisfy { FileManager.default.fileExists(atPath: compiled($0.name).path) } }

    func install() {
        if case .downloading = state { return }
        state = .downloading(0)
        Task {
            do {
                let total = Double(Self.packages.flatMap(\.files).reduce(0) { $0 + $1.size })
                var done = 0.0
                for package in Self.packages {
                    let local = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-sam-\(UUID().uuidString).mlpackage")
                    defer { try? FileManager.default.removeItem(at: local) }
                    for file in package.files {
                        let (download, _) = try await URLSession.shared.download(from: URL(string: Self.repository + package.name + ".mlpackage/" + file.path)!)
                        let data = try Data(contentsOf: download, options: .mappedIfSafe)
                        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                            throw NSError(domain: "Pluck", code: 32, userInfo: [NSLocalizedDescriptionKey: String(localized: "The download didn’t check out. Try again.")])
                        }
                        let target = local.appendingPathComponent(file.path)
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: download, to: target)
                        done += Double(file.size)
                        state = .downloading(done / total)
                    }
                    let made = try await MLModel.compileModel(at: local)
                    try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: Self.compiled(package.name))
                    try FileManager.default.moveItem(at: made, to: Self.compiled(package.name))
                }
                state = .ready
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Finding

    nonisolated(unsafe) private static var models: (encoder: MLModel, prompt: MLModel, decoder: MLModel)?
    /// The last photo's encoding (the slow part: a second click on the same photo only decodes).
    nonisolated(unsafe) private static var encoded: (key: String, features: MLFeatureProvider)?
    nonisolated private static let lock = NSLock()

    /// The object at these points (shares from the top left; `keep` false: points to leave out), as a mask the photo's size
    /// (white: the object). Nil without the model or if nothing was found.
    nonisolated static func object(_ key: String, points: [(CGPoint, keep: Bool)], in image: CIImage, context: CIContext) -> CIImage? {
        guard isReady, !points.isEmpty else { return nil }
        return lock.withLock { () -> CIImage? in
            if models == nil {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                guard let e = try? MLModel(contentsOf: compiled(packages[0].name), configuration: config),
                      let p = try? MLModel(contentsOf: compiled(packages[1].name), configuration: config),
                      let d = try? MLModel(contentsOf: compiled(packages[2].name), configuration: config) else { return nil }
                models = (e, p, d)
            }
            guard let models else { return nil }
            let extent = image.extent
            // The encoding: the photo squeezed into 1024 × 1024 (as the model was made; the points squeezed the same way).
            if encoded?.key != key {
                let square = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                    .concatenating(CGAffineTransform(scaleX: 1024 / extent.width, y: 1024 / extent.height)))
                guard let cg = context.createCGImage(square, from: CGRect(x: 0, y: 0, width: 1024, height: 1024), format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
                      let buffer = pixelBuffer(cg),
                      let features = try? models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
                else { return nil }
                encoded = (key, features)
            }
            guard let features = encoded?.features,
                  let pts = try? MLMultiArray(shape: [1, NSNumber(value: points.count), 2], dataType: .float16),
                  let labels = try? MLMultiArray(shape: [1, NSNumber(value: points.count)], dataType: .float16) else { return nil }
            for (i, point) in points.enumerated() {
                pts[i * 2] = NSNumber(value: point.0.x * 1024); pts[i * 2 + 1] = NSNumber(value: point.0.y * 1024)
                labels[i] = point.keep ? 1 : 0
            }
            guard let prompt = try? models.prompt.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": pts, "labels": labels])),
                  let sparse = prompt.featureValue(for: "sparse_embeddings"), let dense = prompt.featureValue(for: "dense_embeddings"),
                  let decoded = try? models.decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                      "image_embedding": features.featureValue(for: "image_embedding")!, "feats_s0": features.featureValue(for: "feats_s0")!,
                      "feats_s1": features.featureValue(for: "feats_s1")!, "sparse_embedding": sparse, "dense_embedding": dense,
                  ])),
                  let scores = decoded.featureValue(for: "scores")?.multiArrayValue,
                  let masks = decoded.featureValue(for: "low_res_masks")?.multiArrayValue else { return nil }
            // The likeliest of its three answers, as a soft mask (the logits through a sigmoid), rows from the top.
            var best = 0
            for i in 1..<3 where scores[i].floatValue > scores[best].floatValue { best = i }
            var values = [Float](repeating: 0, count: 256 * 256), any = false
            for y in 0..<256 { for x in 0..<256 {
                let logit = masks[[0, NSNumber(value: best), NSNumber(value: y), NSNumber(value: x)]].floatValue
                values[y * 256 + x] = 1 / (1 + exp(-logit * 2)); if logit > 0 { any = true }
            } }
            guard any else { return nil }
            let small = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 256 * 4,
                                size: CGSize(width: 256, height: 256), format: .Lf, colorSpace: nil)
            return small.transformed(by: CGAffineTransform(scaleX: extent.width / 256, y: extent.height / 256)
                .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1]).cropped(to: extent)
        }
    }

    nonisolated private static func pixelBuffer(_ cg: CGImage) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, cg.width, cg.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let made else { return nil }
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        guard let drawing = CGContext(data: CVPixelBufferGetBaseAddress(made), width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(made), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        drawing.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return made
    }
}
