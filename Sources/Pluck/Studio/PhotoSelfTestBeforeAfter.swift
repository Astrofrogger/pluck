import AppKit
import CoreImage

/// Before and after (Task 20): the canvas's composite shows both.
extension PhotoSelfTest {
    static func beforeAfter() async {
        // A dark grey picture, so plus two stops show (the folder's photos may be saturated or clipped).
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-beforeafter-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("grey.jpg")
        let grey = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        guard let jpeg = PhotoEngine.context.jpegRepresentation(of: grey, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              (try? jpeg.write(to: file)) != nil else { return check("split renders both", false, "a grey JPEG written") }
        let path = file.path
        var bright = PhotoRecord()
        bright.adjust.exposure = 2
        guard let before = PhotoRender.image(path, record: PhotoRecord(), maxSize: 600),
              let after = PhotoRender.image(path, record: bright, maxSize: 600) else {
            return check("split renders both", false, "the photo to render")
        }
        // A view the shape of the photo, so it's all photo.
        let view = CGSize(width: 600, height: (600 * before.extent.height / max(before.extent.width, 1)).rounded())
        let frame = CGRect(origin: .zero, size: view)
        func luma(_ picture: CIImage, _ part: CGRect) -> Double {
            let width = Int(part.width), height = Int(part.height)
            var pixels = [Float](repeating: 0, count: width * height * 4)
            pixels.withUnsafeMutableBytes {
                PhotoEngine.context.render(picture, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: part, format: .RGBAf,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            var sum = 0.0
            for i in 0..<(width * height) { sum += 0.2126 * Double(pixels[i * 4]) + 0.7152 * Double(pixels[i * 4 + 1]) + 0.0722 * Double(pixels[i * 4 + 2]) }
            return sum / Double(max(width * height, 1))
        }
        let halfWidth = view.width / 2 - 8
        let left = CGRect(x: 4, y: 0, width: halfWidth, height: view.height), right = CGRect(x: view.width / 2 + 4, y: 0, width: halfWidth, height: view.height)

        let split = PhotoComposite.compose(after: after, before: before, frame: frame, mode: .split, split: 0.5, view: view, scale: 1)
        let l = luma(split, left), r = luma(split, right)
        check("split renders both", r - l > 0.05, "right brighter than left by 0.05; got \(l) and \(r)")

        // Side by side: each half holds a whole photo (frame is the right half's).
        let halfView = CGSize(width: view.width / 2, height: view.height)
        let fitted = PhotoLoupe.fitted(before.extent.size, in: halfView, inset: 0)
        let sideBySide = PhotoComposite.compose(after: after, before: before, frame: fitted.offsetBy(dx: halfView.width, dy: 0),
                                                mode: .sideBySide, split: 0.5, view: view, scale: 1)
        let inner = fitted.insetBy(dx: fitted.width * 0.1, dy: fitted.height * 0.1)
        let sl = luma(sideBySide, CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height).integral)
        let sr = luma(sideBySide, CGRect(x: inner.minX + halfView.width, y: inner.minY, width: inner.width, height: inner.height).integral)
        check("side by side renders both", sr - sl > 0.05, "right brighter than left by 0.05; got \(sl) and \(sr)")

        let x = PhotoComposite.splitX(frame: CGRect(x: -100, y: 0, width: 800, height: 400), view: CGSize(width: 600, height: 400), split: 0.5)
        check("split line stays on the visible part", abs(x - 300) < 0.01, "300; got \(x)")
    }
}
