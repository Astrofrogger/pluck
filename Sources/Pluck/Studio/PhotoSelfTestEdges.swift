import CoreImage
import CoreImage.CIFilterBuiltins
import simd

extension PhotoSelfTest {
    /// Fill Edges: the photo made larger with a filled border, and straightening that keeps the whole frame without black corners.
    static func edgesTest() async {
        var a = PhotoAdjustments()
        a.straighten = 5
        check("edges: off by default", !PhotoEdgeFill.wanted(a))
        guard PhotoRemove.isReady else { skip("edges", "no model"); return }
        a.fillEdges = true
        check("edges: on when straightened", PhotoEdgeFill.wanted(a))

        let context = PhotoEngine.context, linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let ramp = CIFilter.linearGradient()
        ramp.point0 = .zero; ramp.point1 = CGPoint(x: 1200, y: 800)
        ramp.color0 = CIColor(red: 0.3, green: 0.25, blue: 0.1, alpha: 1, colorSpace: linear)!
        ramp.color1 = CIColor(red: 0.1, green: 0.2, blue: 0.35, alpha: 1, colorSpace: linear)!
        let picture = ramp.outputImage!.cropped(to: frame)
        func mean(_ image: CIImage, _ r: CGRect) -> SIMD3<Float> {
            var p = [Float](repeating: 0, count: 4)
            context.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)]),
                           toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            return SIMD3(p[0], p[1], p[2])
        }
        let margin = PhotoEdgeFill.margin(a, frame: frame)
        check("edges: margin covers the turn", margin > 50 && margin < 300, "\(margin)")
        let t0 = Date()
        guard let larger = PhotoEdgeFill.extended(picture, margin: margin, context: context) else { check("edges: border filled", false); return }
        let took = Date().timeIntervalSince(t0)
        if let out = ProcessInfo.processInfo.environment["PLUCK_EDGES_DUMP"] {
            try? context.writePNGRepresentation(of: larger, to: URL(fileURLWithPath: out), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            // A real photo too, straightened 6°, to look at.
            if let folder = UserDefaults.standard.string(forKey: "PluckScreenshotPhotos"),
               let real = PhotoRender.decoded(folder + "/one.jpg", maxSize: 1600, record: PhotoRecord()) {
                var b = a; b.straighten = 6
                let r = real.transformed(by: CGAffineTransform(translationX: -real.extent.minX, y: -real.extent.minY))
                if let big = PhotoEdgeFill.extended(r, margin: PhotoEdgeFill.margin(b, frame: r.extent), context: context) {
                    try? context.writePNGRepresentation(of: big, to: URL(fileURLWithPath: out + ".real.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    try? context.writePNGRepresentation(of: PhotoRender.geometry(big, b, crop: false, frame: r.extent), to: URL(fileURLWithPath: out + ".turned.png"),
                                                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
            }
        }
        check("edges: larger by the margin", larger.extent == frame.insetBy(dx: -margin, dy: -margin), "\(larger.extent)")
        let corner = mean(larger, CGRect(x: -margin, y: -margin, width: margin / 2, height: margin / 2))
        check("edges: border not black", corner.max() > 0.08, "\(corner)")
        check("edges: inside unchanged", simd_length(mean(larger, CGRect(x: 500, y: 300, width: 100, height: 100)) - mean(picture, CGRect(x: 500, y: 300, width: 100, height: 100))) < 0.01)
        let turned = PhotoRender.geometry(larger, a, crop: false, frame: frame)
        check("edges: keeps the whole frame", turned.extent == frame, "\(turned.extent)")
        let c = mean(turned, CGRect(x: 0, y: 0, width: 20, height: 20))
        check("edges: no black corner", c.max() > 0.08, "\(c)")
        print("edges: border filled in \(String(format: "%.2f", took)) s")
    }
}
