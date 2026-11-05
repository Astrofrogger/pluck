import CoreImage

/// The couplers' Edge Effect: lower softens the film's edges, the colour away from them stays.
extension PhotoSelfTest {
    static func couplerEdges() {
        guard let stock = FilmTables.shared.stock(film: "kodak_gold_200", paper: "kodak_portra_endura") else {
            check("coupler edge effect", false, "no stock"); return
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let width = 240, height = 8
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4, v: Float = x < width / 2 ? 0.03 : 0.4
            pixels[i] = v; pixels[i + 1] = v * 0.9; pixels[i + 2] = v * 0.7
        } }
        let scene = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        // A 35 mm frame 6000 px wide: the couplers' 20 µm spread is about 3 px.
        func row(_ edge: Double) -> [Float] {
            var film = FilmSettings()
            film.film = "kodak_gold_200"; film.paper = "kodak_portra_endura"
            film.changed = ["grain_on": .number(0), "halation_on": .number(0), "scan_usm_amount": .number(0), "couplers_edge": .number(edge)]
            let picture = PhotoRender.filmed(scene, stock: stock, film: film, geometry: FilmGeometry(fullLongEdge: 6000))
            var out = [Float](repeating: 0, count: width * height * 4)
            out.withUnsafeMutableBytes {
                PhotoEngine.context.render(picture, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: scene.extent, format: .RGBAf, colorSpace: space)
            }
            return (0..<width).map { out[(height / 2 * width + $0) * 4 + 1] }
        }
        // The overshoot beside the edge on its bright side, over the bright plateau far from it.
        func overshoot(_ r: [Float]) -> Float { (r[(width / 2)...(width / 2 + 12)].max() ?? 0) - r[width - 20] }
        let full = row(1), standard = row(FilmHalation.defaultCouplerEdge), none = row(0)
        check("coupler edge effect", overshoot(full) > overshoot(standard) && overshoot(standard) >= overshoot(none) - 1e-4,
              "overshoot at 1: \(overshoot(full)), at \(FilmHalation.defaultCouplerEdge): \(overshoot(standard)), at 0: \(overshoot(none))")
        check("coupler edge keeps the colour", abs(full[width - 20] - none[width - 20]) < 0.01 && abs(full[20] - none[20]) < 0.01,
              "far from the edge: bright \(full[width - 20]) vs \(none[width - 20]), dark \(full[20]) vs \(none[20])")
    }
}
