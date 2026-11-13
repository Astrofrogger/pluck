import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Soft proofing: sRGB leaves in-gamut colours alone, a wider colour is pulled in and marked, a CMYK
/// profile changes saturated colours, it is quick enough to use while editing, and an export can
/// carry the proof's profile.
extension PhotoSelfTest {
    private static let p3Space = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let extendedSRGB = CGColorSpace(name: CGColorSpace.extendedSRGB)!

    private static func flat(_ c: SIMD3<Float>, in space: CGColorSpace) -> CIImage {
        var pixels = [Float](repeating: 1, count: 64 * 4)
        for i in 0..<64 { pixels[i * 4] = c.x; pixels[i * 4 + 1] = c.y; pixels[i * 4 + 2] = c.z }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: 8 * 16, size: CGSize(width: 8, height: 8),
                       format: .RGBAf, colorSpace: space)
    }

    private static func middle(_ image: CIImage, in space: CGColorSpace) -> SIMD3<Float> {
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
                                       format: .RGBAf, colorSpace: space)
        }
        return SIMD3(px[0], px[1], px[2])
    }

    private static func far(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }

    static func softProof() async {
        // The mark's own colour, as the render sees it.
        let mark = middle(CIImage(color: PhotoProof.warning).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)), in: srgbSpace)
        func proofed(_ c: SIMD3<Float>, _ space: CGColorSpace, _ p: PhotoProof) -> (shown: SIMD3<Float>, marked: Bool) {
            var p = p
            p.on = true
            p.makeTable()
            let image = flat(c, in: space)
            let shown = middle(p.apply(image, gamut: false), in: space)
            let marked = far(middle(p.apply(image, gamut: true), in: srgbSpace), mark) < 0.02
            return (shown, marked)
        }

        // sRGB: colours inside it come back as they went in, unmarked.
        var toSRGB = PhotoProof()
        toSRGB.target = .srgb
        var worst: Float = 0
        var anyMarked = false
        for c: SIMD3<Float> in [[0.5, 0.4, 0.3], [0.2, 0.5, 0.7], [0.9, 0.85, 0.8], [0.05, 0.05, 0.06], [0.6, 0.6, 0.6]] {
            let r = proofed(c, srgbSpace, toSRGB)
            worst = max(worst, far(r.shown, c))
            anyMarked = anyMarked || r.marked
        }
        check("softproof srgb keeps in-gamut", worst < 0.02 && !anyMarked, "worst change \(worst), marked \(anyMarked)")

        // A saturated Display P3 green is outside sRGB: pulled in, and marked.
        let green: SIMD3<Float> = [0.05, 0.95, 0.15]
        let r = proofed(green, p3Space, toSRGB)
        let inSRGB = middle(flat(r.shown, in: p3Space), in: extendedSRGB)
        let before = middle(flat(green, in: p3Space), in: extendedSRGB)
        check("softproof wide colour pulled into srgb", far(r.shown, green) > 0.03 && inSRGB.min() > -0.02 && before.min() < -0.05,
              "change \(far(r.shown, green)), proofed in sRGB \(inSRGB), original in sRGB \(before)")
        check("softproof gamut warning marks it", r.marked)

        // A CMYK profile from the system.
        guard let cmyk = PhotoProof.installed.first(where: { $0.cmyk && $0.name.contains("Generic CMYK") }) ?? PhotoProof.installed.first(where: \.cmyk) else {
            skip("softproof cmyk", "no CMYK profile installed")
            return
        }
        note("softproof profiles installed: \(PhotoProof.installed.count), CMYK used: \(cmyk.name)")
        var toCMYK = PhotoProof()
        toCMYK.target = .profile(cmyk.path)
        let started = Date()
        toCMYK.on = true
        toCMYK.makeTable()
        note("softproof CMYK colour table: \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        var changed = true, allMarked = true
        for c: SIMD3<Float> in [[0.0, 0.2, 1.0], [0.05, 0.95, 0.15], [1.0, 0.0, 0.5]] {
            let q = proofed(c, srgbSpace, toCMYK)
            changed = changed && far(q.shown, c) > 0.05
            allMarked = allMarked && q.marked
        }
        check("softproof cmyk changes saturated colours", changed)
        check("softproof cmyk marks them", allMarked)
        var paper = toCMYK
        paper.paper = true
        let white = proofed([1, 1, 1], srgbSpace, paper).shown
        check("softproof paper simulation dims white", white.min() < 0.99 && proofed([1, 1, 1], srgbSpace, toCMYK).shown.min() > 0.98, "paper white \(white), relative white \(proofed([1, 1, 1], srgbSpace, toCMYK).shown)")

        // Speed: a real photo at preview size, proofed with the gamut warning on, drawn.
        if let file = try? FileManager.default.contentsOfDirectory(atPath: photos).first(where: { $0.lowercased().hasSuffix(".jpg") }),
           let source = CIImage(contentsOf: URL(fileURLWithPath: photos + "/" + file)) {
            let scale = 2048 / max(source.extent.width, source.extent.height)
            let image = source.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
            var p = toCMYK
            p.gamutWarning = true
            var times: [Double] = []
            for run in 0..<6 {
                let t = Date()
                _ = PhotoEngine.context.createCGImage(p.apply(image), from: image.extent, format: .RGBA8, colorSpace: p3Space)
                if run > 0 { times.append(Date().timeIntervalSince(t) * 1000) }
            }
            let ms = times.reduce(0, +) / Double(times.count)
            note("softproof \(Int(image.extent.width))x\(Int(image.extent.height)) with gamut warning: \(Int(ms)) ms per frame")
            check("softproof is quick enough", ms < 150, "\(ms) ms")
        } else {
            skip("softproof speed", "no photo in \(photos)")
        }

        // An export can carry the proof's RGB profile.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-proof-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = folder.appendingPathComponent("grey.png")
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: srgbSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        if let destination = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            CGImageDestinationFinalize(destination)
        }
        var proof = PhotoProof()
        proof.on = true
        proof.target = .adobe
        let out = try? await PhotoRender.export(png.path, record: PhotoRecord(), to: folder.appendingPathComponent("out"), settings: PhotoExportSettings(), proof: proof)
        let name = out.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.colorSpace?.name as String?
        check("softproof export embeds the profile", name == (CGColorSpace.adobeRGB1998 as String), "got \(name ?? "none")")
    }
}
