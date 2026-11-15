import AppKit
import ImageIO
import SwiftUI
import Vision

/// Thumbnail Maker (-PluckScreenshotOnly thumbnails2): a clip made with ffmpeg — blurred, black, a sharp
/// part dissolving into a photo with a face (from PLUCK_PEOPLE_DIR when there is one). The picks avoid the
/// blur, the black and the dissolve, the best is the face; every size comes out at its pixels with the text
/// readable; the designer page is drawn off screen beside the log.
extension PhotoSelfTest {
    static func thumbnails2Test() async {
        guard let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg") else { return check("thumbnails2: ffmpeg", false, "no ffmpeg") }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Thumbnails2Test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A photo with a face, cropped to 16:9 round it.
        var hasFace = false
        let still = folder.appendingPathComponent("face.png")
        if let dir = ProcessInfo.processInfo.environment["PLUCK_PEOPLE_DIR"],
           let files = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { continue }
                let faces = VNDetectFaceRectanglesRequest()
                try? VNImageRequestHandler(cgImage: preview).perform([faces])
                guard let face = (faces.results ?? []).first(where: { $0.boundingBox.height > 0.12 }) else { continue }
                let crop = ThumbnailMaker.aspectFill(CIImage(cgImage: preview), into: CGSize(width: 960, height: 540),
                                                     focus: CGPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY))
                if let cg = CIContext().createCGImage(crop, from: crop.extent), (try? ThumbnailMaker.write(cg, to: still, format: .png)) != nil { hasFace = true; break }
            }
        }
        let size = "960x540"
        let photo = hasFace ? ["-loop", "1", "-framerate", "25", "-t", "3", "-i", still.path] : ["-f", "lavfi", "-i", "mandelbrot=s=\(size):r=25,trim=duration=3"]
        // 0–2 s blurred, 2–3 s black, 3–4 s sharp, 4–5 s dissolving into the photo, 5–7 s the photo.
        let clip = folder.appendingPathComponent("clip.mov")
        let graph = "[0]gblur=sigma=14,settb=AVTB,format=yuv420p[a];[1]settb=AVTB,format=yuv420p[b];"
            + "[2]settb=AVTB,format=yuv420p[c];[3]scale=960:540,setsar=1,fps=25,settb=AVTB,format=yuv420p[d];"
            + "[c][d]xfade=transition=fade:duration=1:offset=1[cd];[a][b][cd]concat=n=3:v=1:a=0[v]"
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y",
                                                "-f", "lavfi", "-i", "testsrc2=s=\(size):r=25:d=2",
                                                "-f", "lavfi", "-i", "color=black:s=\(size):r=25:d=1",
                                                "-f", "lavfi", "-i", "testsrc2=s=\(size):r=25:d=2"] + photo
                                       + ["-filter_complex", graph, "-map", "[v]", "-c:v", "mpeg4", "-q:v", "2", "-pix_fmt", "yuv420p", clip.path])
        guard FileManager.default.fileExists(atPath: clip.path) else { return check("thumbnails2: clip made", false) }
        check("thumbnails2: face photo found", hasFace, "no face in PLUCK_PEOPLE_DIR: the sharp part is a pattern")

        guard let samples = try? await ThumbnailMaker.samples(clip, ffmpeg: ffmpeg) else { return check("thumbnails2: frames looked at", false) }
        let picks = ThumbnailMaker.pick(samples)
        func list(_ s: [ThumbnailMaker.Sample]) -> String {
            s.map { String(format: "%.2f:%.2f%@%@", $0.time, $0.score, $0.faces > 0 ? "f" : "", $0.rejected.isEmpty ? "" : "[" + $0.rejected.joined(separator: ",") + "]") }.joined(separator: " ")
        }
        check("thumbnails2: frames picked", !picks.isEmpty && picks.count <= 12, list(picks))
        check("thumbnails2: no blurred pick", !picks.contains { $0.time < 2 }, list(picks))
        check("thumbnails2: no black pick", !picks.contains { (2...3).contains($0.time) }, list(picks))
        check("thumbnails2: no mid-dissolve pick", !picks.contains { (4.05...4.95).contains($0.time) }, list(picks) + " ~ " + list(samples.filter { (3.5...5.5).contains($0.time) }))
        check("thumbnails2: blur marked soft", samples.filter { (0.3...1.7).contains($0.time) }.allSatisfy { $0.rejected.contains("soft") }, list(samples))
        check("thumbnails2: black marked", samples.filter { (2.15...2.85).contains($0.time) }.allSatisfy { $0.rejected.contains("black") }, list(samples))
        check("thumbnails2: dissolve marked", samples.filter { (4.2...4.8).contains($0.time) }.allSatisfy { $0.rejected.contains("transition") }, list(samples))
        if let top = picks.first {
            check("thumbnails2: top pick from the sharp part", top.time >= 3 && (!hasFace || (top.time > 5 && top.faces > 0 && top.eyesOpen)), list(picks))
        }

        // Every size at its pixels, the text readable, in a light brand colour that needs help on a bright picture.
        guard let best = picks.first, let frame = await ThumbnailMaker.frame(clip, at: best.time) else { return check("thumbnails2: full frame", false) }
        let mark = CGContext(data: nil, width: 200, height: 80, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        mark.setFillColor(CGColor(gray: 1, alpha: 1))
        mark.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 200, height: 80), cornerWidth: 40, cornerHeight: 40, transform: nil))
        mark.fillPath()
        let logo = mark.makeImage()
        let brand = ThumbnailMaker.Brand(palette: BrandPalette(colours: [MotionColor(r: 0.98, g: 0.82, b: 0.15), MotionColor(r: 0.1, g: 0.3, b: 0.8)]),
                                         font: "Helvetica Neue", logo: logo)
        var design = ThumbnailMaker.Design(title: "Summer Launch Recap", subtitle: "Behind the scenes", exposure: 0.1, saturation: 0.1, sharpen: 0.3, vignette: 0.3)
        let shots = (UserDefaults.standard.string(forKey: "PluckScreenshotLog") ?? folder.path) + "-thumbs"
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        for size in ThumbnailMaker.Size.allCases {
            let r = ThumbnailMaker.render(frame, focus: best.focus, design: design, brand: brand, size: size)
            check("thumbnails2: \(size.rawValue) is \(Int(size.pixels.width))×\(Int(size.pixels.height))",
                  r.map { CGFloat($0.image.width) == size.pixels.width && CGFloat($0.image.height) == size.pixels.height } ?? false)
            check("thumbnails2: \(size.rawValue) text contrast", (r?.contrast ?? 0) >= ThumbnailMaker.minimumContrast, "\(r?.contrast ?? 0)")
            if let r { try? ThumbnailMaker.write(r.image, to: URL(fileURLWithPath: shots).appendingPathComponent("\(size.rawValue).jpg"), format: .jpeg) }
        }
        for layout in ThumbnailMaker.Layout.allCases {
            design.layout = layout
            let r = ThumbnailMaker.render(frame, focus: best.focus, design: design, brand: brand, size: .youtube)
            check("thumbnails2: \(layout.rawValue) layout text contrast", (r?.contrast ?? 0) >= ThumbnailMaker.minimumContrast, "\(r?.contrast ?? 0)")
            if let r { try? ThumbnailMaker.write(r.image, to: URL(fileURLWithPath: shots).appendingPathComponent("layout-\(layout.rawValue).jpg"), format: .jpeg) }
        }
        // A mid-grey picture with a mid-grey brand: the plate keeps it readable.
        let grey = CIContext().createCGImage(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360)),
                                             from: CGRect(x: 0, y: 0, width: 640, height: 360))!
        let greyBrand = ThumbnailMaker.Brand(palette: BrandPalette(colours: [MotionColor(r: 0.5, g: 0.5, b: 0.5)]), font: "Helvetica Neue", logo: nil)
        design.layout = .cornerLogo
        let flat = ThumbnailMaker.render(grey, focus: CGPoint(x: 0.5, y: 0.5), design: design, brand: greyBrand, size: .square)
        check("thumbnails2: grey on grey still readable", (flat?.contrast ?? 0) >= ThumbnailMaker.minimumContrast, "\(flat?.contrast ?? 0)")

        // Saved files keep their size and format.
        if let r = ThumbnailMaker.render(frame, focus: best.focus, design: design, brand: brand, size: .vertical) {
            for format in ThumbnailMaker.Format.allCases {
                let url = folder.appendingPathComponent("out.\(format.fileExtension)")
                try? ThumbnailMaker.write(r.image, to: url, format: format)
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
                let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                check("thumbnails2: \(format.rawValue) saved 1080×1920",
                      (props?[kCGImagePropertyPixelWidth] as? Int) == 1080 && (props?[kCGImagePropertyPixelHeight] as? Int) == 1920
                      && source.flatMap { CGImageSourceGetType($0) as String? } == format.type.identifier)
            }
        }
        // Batch: the same design on two videos, one file each.
        var plain = ThumbnailMaker.Design(); plain.layout = .bigTitle
        let made = await ThumbnailMaker.batch([clip, clip], design: plain, brand: brand, sizes: [.square], format: .png, to: folder, ffmpeg: ffmpeg)
        check("thumbnails2: batch writes each video", made.count == 2 && made.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "\(made.count)")

        // The designer page drawn off screen (never shown), for looking at.
        if let log = UserDefaults.standard.string(forKey: "PluckScreenshotLog") {
            ThumbnailMakerView.openFile = clip
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1180, height: 940), styleMask: [.borderless], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = NSHostingView(rootView: ThumbnailMakerView().environment(\.colorScheme, .dark))
            try? await Task.sleep(for: .seconds(15))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + "-designer.png"))
            }
            window.contentView = nil
            window.close()
        }
    }
}
