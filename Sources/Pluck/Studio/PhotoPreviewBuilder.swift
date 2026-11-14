import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screen-size previews made ahead (as Lightroom's standard previews): every photo of the album open gets its picture at the
/// screen's size saved, one at a time in the background, so the large view shows it the moment a photo is chosen and the
/// exact picture that follows looks the same. Waits while the large view is working.
@MainActor
final class PhotoPreviewBuilder {
    static let shared = PhotoPreviewBuilder()
    private var waiting: [String] = []
    private var working = false
    /// When the large view last asked for a picture: the builder keeps out of its way for a moment after.
    var lastAsked = Date.distantPast

    /// The screen-size preview next to the grid's copy.
    nonisolated static func screenFile(_ cached: URL) -> URL {
        cached.deletingPathExtension().appendingPathExtension("screen.jpg")
    }

    /// Writes a screen-size preview (JPEG, high quality).
    nonisolated static func save(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// These photos (the album shown), the first first.
    func enqueue(_ paths: [String]) {
        waiting = paths
        guard !working else { return }
        working = true
        Task {
            while !waiting.isEmpty {
                let path = waiting.removeFirst()
                // Out of the large view's way.
                while Date.now.timeIntervalSince(lastAsked) < 1.5 { try? await Task.sleep(for: .milliseconds(300)) }
                let record = PhotoCatalog.shared.record(path)
                let screen = Self.screenFile(PhotoRender.cachedPreview(path, record: record))
                guard !FileManager.default.fileExists(atPath: screen.path) else { continue }
                // (Films made by the helper come when shown; the shipped ones here.)
                let film = record.film
                if record.filmOn, await Task.detached(priority: .utility, operation: { FilmRoute.resolved(film) }).value != .instant { continue }
                let size = PhotoRender.previewSize
                await Task.detached(priority: .utility) {
                    guard let image = PhotoRender.image(path, record: record, maxSize: size),
                          let picture = PhotoRender.picture(image, maxSize: size, space: PhotoRender.screenSpace) else { return }
                    Self.save(picture, to: screen)
                }.value
            }
            working = false
        }
    }
}
