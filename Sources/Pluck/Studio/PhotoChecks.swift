import CoreImage
import Foundation
import ImageIO
import Vision

/// What a quick look at a photo finds, to help cull (it never rejects anything itself): how
/// sharp it is (on the faces when there are any), whether eyes are closed, where the faces are,
/// and when it was taken (for bursts). From the camera's own preview, on this Mac.
struct PhotoCheck: Codable, Hashable {
    var sharpness: Double
    var faces: [CGRect]
    var eyesClosed: Bool
    var taken: Date?

    /// Below this it looks soft (from the camera's preview at 1024 px).
    static let softBelow = 0.012
    var looksSoft: Bool { sharpness < Self.softBelow }
    var possibleReject: Bool { looksSoft || eyesClosed }
}

/// The checks of the photos Pluck knows, worked out in the background and kept on disk.
@MainActor
@Observable
final class PhotoChecks {
    static let shared = PhotoChecks()
    private(set) var checks: [String: PhotoCheck] = [:]
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var saveScheduled = false
    private static let version = 1

    nonisolated private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Photo Checks.json")
    }

    private struct Saved: Codable {
        var version: Int
        var checks: [String: PhotoCheck]
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.version {
            checks = saved.checks
        }
    }

    func check(_ path: String) -> PhotoCheck? { checks[path] }

    /// Looks at these photos (the ones not seen yet), one after the other, in the background.
    func enqueue(_ paths: [String]) {
        let new = paths.filter { checks[$0] == nil && !waiting.contains($0) }
        guard !new.isEmpty else { return }
        waiting.append(contentsOf: new)
        guard !running else { return }
        running = true
        Task {
            while !waiting.isEmpty {
                let path = waiting.removeFirst()
                if let found = await Task.detached(priority: .utility, operation: { Self.look(at: path) }).value {
                    checks[path] = found
                    scheduleSave()
                }
            }
            running = false
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            saveScheduled = false
            let saved = Saved(version: Self.version, checks: checks)
            await Task.detached(priority: .background) {
                try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
            }.value
        }
    }

    // MARK: - Bursts

    /// The photos in bursts: neighbours taken within a second and a half of each other, in the
    /// order given. Each group's first is the one to show: the sharpest with eyes open.
    func bursts(_ photos: [String]) -> [[String]] {
        var groups: [[String]] = []
        for path in photos {
            if let last = groups.last?.last, let a = checks[last]?.taken, let b = checks[path]?.taken, abs(b.timeIntervalSince(a)) <= 1.5 {
                groups[groups.count - 1].append(path)
            } else {
                groups.append([path])
            }
        }
        return groups.map { group in
            guard group.count > 1 else { return group }
            let best = group.max { score($0) < score($1) } ?? group[0]
            return [best] + group.filter { $0 != best }
        }
    }

    private func score(_ path: String) -> Double {
        guard let check = checks[path] else { return 0 }
        return check.sharpness - (check.eyesClosed ? 1 : 0)
    }

    // MARK: - Looking

    nonisolated private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    nonisolated static func look(at path: String) -> PhotoCheck? {
        let url = URL(fileURLWithPath: PhotoCatalog.file(of: path))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Faces, with their eyes.
        let faces = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: preview).perform([faces])
        let found = (faces.results ?? []).filter { $0.boundingBox.width > 0.04 }
        let closed = found.contains { face in
            guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else { return false }
            return openness(left) < 0.16 && openness(right) < 0.16
        }
        // Sharpness: how strong the finest edges are (a Laplacian), on the faces if any.
        let picture = CIImage(cgImage: preview)
        let e = picture.extent
        var area = e
        if let union = found.map(\.boundingBox).reduce(nil, { (sum: CGRect?, box: CGRect) in sum?.union(box) ?? box }) {
            area = CGRect(x: e.minX + union.minX * e.width, y: e.minY + union.minY * e.height, width: union.width * e.width,
                          height: union.height * e.height).insetBy(dx: -8, dy: -8).intersection(e)
        }
        let edges = picture.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIConvolution3X3", parameters: ["inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0])
        let squared = edges.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: edges])
        let average = squared.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: area.insetBy(dx: 2, dy: 2))])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let sharpness = Double(pixel[0]).squareRoot()
        return PhotoCheck(sharpness: sharpness, faces: found.map(\.boundingBox), eyesClosed: closed,
                          taken: PhotoImportSheet.captureDate(url))
    }

    /// How open an eye is: its height over its width (an eye's outline from Vision).
    nonisolated private static func openness(_ eye: VNFaceLandmarkRegion2D) -> Double {
        let points = eye.normalizedPoints
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 1 }
        return Double((maxY - minY) / (maxX - minX))
    }
}
