import ImageIO
import UniformTypeIdentifiers

/// Several export presets at once, and the watermark (Task 17).
extension PhotoSelfTest {
    static func exportPresets() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func black(_ name: String, _ width: Int, _ height: Int) -> URL {
            let url = folder.appendingPathComponent(name)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                CGImageDestinationFinalize(destination)
            }
            return url
        }
        func size(of url: URL?) -> (Int, Int)? {
            guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return (w, h)
        }

        // Web and Social on one photo: two files, in their folders.
        let photo = black("street.png", 2400, 1600)
        let out = folder.appendingPathComponent("out", isDirectory: true)
        var web = PhotoExportPreset.builtIn.first { $0.settings.longSide == 2048 }?.settings ?? PhotoExportSettings()
        var social = PhotoExportPreset.builtIn.first { $0.settings.longSide == 1080 }?.settings ?? PhotoExportSettings()
        web.subfolder = "Web"
        social.subfolder = "Social"
        let a = try? await PhotoRender.export(photo.path, record: PhotoRecord(), to: out, settings: web)
        let b = try? await PhotoRender.export(photo.path, record: PhotoRecord(), to: out, settings: social)
        let sizeA = size(of: a), sizeB = size(of: b)
        check("two presets two files", sizeA?.0 == 2048 && sizeB?.0 == 1080 && a?.deletingLastPathComponent().lastPathComponent == "Web"
              && b?.deletingLastPathComponent().lastPathComponent == "Social" && a != b,
              "2048 in Web, 1080 in Social; got \(String(describing: sizeA)) in \(a?.deletingLastPathComponent().lastPathComponent ?? "-"), \(String(describing: sizeB)) in \(b?.deletingLastPathComponent().lastPathComponent ?? "-")")

        // A suffix, and a second export of the same name.
        var tagged = web
        tagged.suffix = "-web"
        let c = try? await PhotoRender.export(photo.path, record: PhotoRecord(), to: out, settings: tagged)
        let d = try? await PhotoRender.export(photo.path, record: PhotoRecord(), to: out, settings: tagged)
        check("suffix and name clash", c?.deletingPathExtension().lastPathComponent == "street-web" && d != nil && d != c,
              "street-web, then another name; got \(c?.lastPathComponent ?? "-"), \(d?.lastPathComponent ?? "-")")

        // A white mark on a black photo lands in the bottom right ninth.
        let dark = black("dark.png", 600, 400)
        var marked = PhotoExportSettings()
        marked.format = .png
        var mark = PhotoWatermark()
        mark.text = "Anna"
        mark.size = 0.05
        mark.opacity = 1
        marked.watermark = mark
        let made = try? await PhotoRender.export(dark.path, record: PhotoRecord(), to: out, settings: marked)
        var box: (x0: Int, y0: Int, x1: Int, y1: Int)?
        var width = 0, height = 0
        if let made, let source = CGImageSourceCreateWithURL(made as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            width = image.width; height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            for y in 0..<height {
                for x in 0..<width where pixels[(y * width + x) * 4] > 100 {
                    // Row 0 is the top.
                    box = (min(box?.x0 ?? x, x), min(box?.y0 ?? y, y), max(box?.x1 ?? x, x), max(box?.y1 ?? y, y))
                }
            }
        }
        check("watermark lands bottom right", box.map { $0.x0 >= width * 2 / 3 && $0.y0 >= height * 2 / 3 } ?? false,
              "bright pixels inside x >= \(width * 2 / 3), y >= \(height * 2 / 3); got \(String(describing: box))")

        // Settings saved by 3.6.2 have none of the new keys.
        let json = #"{"format":"jpeg","quality":0.85,"longSide":2048,"space":"srgb","sharpen":"screen","hdr":false,"metadata":"noLocation","naming":"original","name":""}"#
        let old = try? JSONDecoder().decode(PhotoExportSettings.self, from: Data(json.utf8))
        check("old export settings decode", old != nil && old?.watermark == nil && old?.suffix == "" && old?.subfolder == "" && old?.longSide == 2048,
              "watermark nil, suffix empty, 2048; got \(String(describing: old))")
        let round = try? JSONDecoder().decode(PhotoExportSettings.self, from: JSONEncoder().encode(marked))
        check("watermark survives saving", round?.watermark == mark, "the same mark; got \(String(describing: round?.watermark))")
    }
}
