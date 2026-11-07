import CoreImage

/// Calibration (the primaries and the shadows tint) on made-up colours (no photo files needed).
extension PhotoSelfTest {
    private static let calibrationSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// One colour (linear light) developed: the middle pixel.
    private static func developed(_ colour: SIMD3<Float>, _ a: PhotoAdjustments, scene: Bool = false) -> SIMD3<Float> {
        let size = 8
        var pixels = [Float](repeating: 1, count: size * size * 4)
        for i in 0..<(size * size) { pixels[i * 4] = colour.x; pixels[i * 4 + 1] = colour.y; pixels[i * 4 + 2] = colour.z }
        let image = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: size * 16,
                            size: CGSize(width: size, height: size), format: .RGBAf, colorSpace: calibrationSpace)
        let out = PhotoRender.adjusted(image, a, isRaw: true, kelvin: 6500, scene: scene)
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(out, toBitmap: $0.baseAddress!, rowBytes: 16,
                                       bounds: CGRect(x: out.extent.midX, y: out.extent.midY, width: 1, height: 1), format: .RGBAf, colorSpace: calibrationSpace)
        }
        return SIMD3(px[0], px[1], px[2])
    }

    private static func with(_ change: (inout Calibration) -> Void, process: Int = PhotoAdjustments.currentProcess) -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.process = process
        change(&a.calibration)
        return a
    }

    // (OkLab chroma: the profiles' density darkens a strong colour at the same chroma, which raises its HSV saturation.)
    private static func colourfulness(_ c: SIMD3<Float>) -> Float {
        let (_, a, b) = OkLab.from(Double(c.x), Double(c.y), Double(c.z)); return Float((a * a + b * b).squareRoot())
    }
    private static func apart(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    private static func greyness(_ c: SIMD3<Float>) -> Float { c.max() - c.min() }

    static func calibration() {
        let red = SIMD3<Float>(0.4, 0.02, 0.02), blue = SIMD3<Float>(0.02, 0.04, 0.4), grey = SIMD3<Float>(0.18, 0.18, 0.18)
        let colours = [red, blue, grey, SIMD3(0.05, 0.3, 0.08), SIMD3(0.9, 0.6, 0.2), SIMD3(0.005, 0.004, 0.006)]

        // Zeros: the identity, and every colour developed exactly as without it (both engines).
        let identity = PhotoEngine.calibration(Calibration())
        let off = zip(identity, [1.0, 0, 0, 0, 1, 0, 0, 0, 1]).map { abs($0 - $1) }.max() ?? 1
        check("calibration zeros are the identity", off < 1e-9, "largest difference \(off)")
        for process in [1, 2] {
            var plain = PhotoAdjustments()
            plain.process = process
            let same = colours.allSatisfy { developed($0, plain) == developed($0, with({ $0 = Calibration() }, process: process)) }
            check("calibration zeros change nothing (process \(process))", same, "every colour pixel-exact")
        }

        // Red hue: + towards orange (more green than blue), − towards magenta; grey stays grey.
        let warmer = developed(red, with { $0.redHue = 100 }), cooler = developed(red, with { $0.redHue = -100 })
        check("red hue +100 towards orange", warmer.y > warmer.z + 0.01, "green over blue; got \(warmer)")
        check("red hue −100 towards magenta", cooler.z > cooler.y + 0.01, "blue over green; got \(cooler)")
        let all = with {
            $0.redHue = 100; $0.redSaturation = -60; $0.greenHue = -80; $0.greenSaturation = 70; $0.blueHue = 50; $0.blueSaturation = -100
        }
        check("calibration keeps grey grey", greyness(developed(grey, all)) < 1e-3 && greyness(developed(grey, all, scene: true)) < 1e-3,
              "within 1e-3; got \(developed(grey, all)), scene \(developed(grey, all, scene: true))")

        // Blue saturation −100: the blue much less colourful, greys as they were.
        let plainBlue = colourfulness(developed(blue, PhotoAdjustments())), dull = colourfulness(developed(blue, with { $0.blueSaturation = -100 }))
        let greyBefore = developed(grey, PhotoAdjustments()), greyAfter = developed(grey, with { $0.blueSaturation = -100 })
        check("blue saturation −100 dulls blue", dull < plainBlue * 0.8, "below 80% of \(plainBlue); got \(dull)")
        check("blue saturation leaves grey", apart(greyAfter, greyBefore) < 1e-3, "\(greyBefore); got \(greyAfter)")

        // Shadows tint: dark grey magenta (+) or green (−), mid grey nearly as it was.
        let dark = SIMD3<Float>(0.01, 0.01, 0.01)
        let magenta = developed(dark, with { $0.shadowTint = 100 }), green = developed(dark, with { $0.shadowTint = -100 })
        check("shadows tint +100 magenta", magenta.x > magenta.y * 1.05 && magenta.z > magenta.y * 1.05, "red and blue over green; got \(magenta)")
        check("shadows tint −100 green", green.y > green.x * 1.05 && green.y > green.z * 1.05, "green over red and blue; got \(green)")
        let mid = developed(grey, with { $0.shadowTint = 100 })
        check("shadows tint leaves mid grey", apart(mid, greyBefore) < 1e-3, "\(greyBefore); got \(mid)")

        // With film: both reach the scene light the film is made from.
        let sceneRed = developed(red, with { $0.redHue = 100 }, scene: true), sceneDark = developed(dark, with { $0.shadowTint = 100 }, scene: true)
        check("calibration reaches the film's scene", sceneRed.y > sceneRed.z * 1.5 && sceneDark.x > sceneDark.y * 1.05,
              "red hue: green over blue, tint: red over green; got \(sceneRed), \(sceneDark)")

        // Lightroom's keys.
        let (imported, unmapped) = LightroomPresets.adjustments(["RedHue": "+20", "BlueSaturation": "-30", "ShadowTint": "+5", "CameraProfile": "Camera Calibration"])
        check("calibration from lightroom", imported.calibration == Calibration(redHue: 20, blueSaturation: -30, shadowTint: 5) && unmapped.isEmpty,
              "20, -30, 5 and nothing unmapped; got \(imported.calibration), \(unmapped)")

        // Saved before Calibration: still reads, with zeros.
        var saved = PhotoAdjustments()
        saved.exposure = 0.5
        var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))) as? [String: Any] ?? [:]
        let had = json.removeValue(forKey: "calibration") != nil
        let old = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        check("old settings without calibration decode", had && old?.exposure == 0.5 && old?.calibration == Calibration(),
              "exposure 0.5, calibration zeros; got \(String(describing: old))")
    }
}
