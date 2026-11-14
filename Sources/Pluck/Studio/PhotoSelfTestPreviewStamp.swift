import CoreGraphics
import Foundation

/// A photo another app saved over (same path) gets new previews, and the old ones go (-PluckScreenshotOnly previewstamp).
extension PhotoSelfTest {
    static func previewStamp() {
        let path = NSTemporaryDirectory() + "pluck-stamp-\(UUID().uuidString).jpg"
        try? Data(count: 100).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = PhotoRecord()
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let before = PhotoRender.cachedPreview(path, record: record)
        check("preview key: same for an unchanged file", PhotoRender.cachedPreview(path, record: record) == before)
        PhotoRender.savePreview(image, to: before)
        check("preview key: the first preview is saved", FileManager.default.fileExists(atPath: before.path))
        try? FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)], ofItemAtPath: path)
        let after = PhotoRender.cachedPreview(path, record: record)
        check("preview key: changes when the file is touched", after != before)
        PhotoRender.savePreview(image, to: after)
        check("preview key: the old preview is let go", !FileManager.default.fileExists(atPath: before.path) && FileManager.default.fileExists(atPath: after.path))
        try? FileManager.default.removeItem(at: after)
    }
}
