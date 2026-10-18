import AppKit
import QuickLookThumbnailing
import os

private let trace = Logger(subsystem: "be.wideopen.pluck.quicklook", category: "thumbnail")

/// Finder's icons for RED and Blackmagic RAW clips: a frame a second in.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        trace.log("thumbnail for \(request.fileURL.path, privacy: .public)")
        do {
            let clip = try RawClip(url: RawClip.clipFile(request.fileURL))
            trace.log("opened \(clip.width)×\(clip.height)")
            defer { clip.close() }
            let wanted = max(request.maximumSize.width, request.maximumSize.height) * request.scale
            let image = try clip.frame(min(Int(clip.fps), max(clip.frames - 1, 0)), scale: clip.scale(forWidth: wanted))
            // Fitted to the size asked for, keeping its shape.
            let ratio = Double(image.width) / Double(max(image.height, 1))
            let box = request.maximumSize
            let size = ratio >= box.width / max(box.height, 1) ? CGSize(width: box.width, height: box.width / ratio)
                : CGSize(width: box.height * ratio, height: box.height)
            handler(QLThumbnailReply(contextSize: size) { context in
                context.draw(image, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch {
            trace.error("failed: \(String(describing: error), privacy: .public)")
            handler(nil, error)
        }
    }
}
