import CoreImage

/// What else Lightroom presets carry (Lightroom presets task 2): the parametric curve, split toning and
/// the grading's blending and balance, the vignette's shape, grain, and process 2010's sliders.
extension PhotoSelfTest {
    private static let extrasSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A picture (linear light) from a colour for each pixel.
    private static func picture(_ width: Int, _ height: Int, _ colour: (Int, Int) -> SIMD3<Float>) -> CIImage {
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = colour(x, y), i = (y * width + x) * 4
                pixels[i] = c.x; pixels[i + 1] = c.y; pixels[i + 2] = c.z
            }
        }
        return CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: extrasSpace)
    }

    /// Every pixel's red, row by row.
    private static func reds(_ image: CIImage) -> [Float] {
        let extent = image.extent.integral, width = Int(extent.width), height = Int(extent.height)
        var px = [Float](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes {
            PhotoEngine.context.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: extrasSpace)
        }
        return stride(from: 0, to: px.count, by: 4).map { px[$0] }
    }

    /// One pixel's red (the pictures here are symmetric top to bottom, so which way rows count doesn't matter).
    private static func red(_ image: CIImage, _ x: Int, _ y: Int) -> Float {
        reds(image)[y * Int(image.extent.width) + x]
    }

    private static func spread(_ values: [Float]) -> Float {
        let mean = values.reduce(0, +) / Float(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
    }

    static func lightroomExtras() {
        // Parametric curve: baked into the master, on top of the point curve; black and white stay put.
        let lifted = LightroomPresets.adjustments(["ParametricShadows": "+50", "ParametricShadowSplit": "25", "ParametricMidtoneSplit": "50",
                                                   "ParametricHighlightSplit": "75"])
        let liftedCurve = Curve(lifted.0.curves.master)
        check("parametric shadows lift the shadows", liftedCurve.value(0.125) > 0.18 && liftedCurve.value(0) == 0 && liftedCurve.value(1) == 1
              && abs(liftedCurve.value(0.875) - 0.875) < 0.01 && lifted.unmapped.isEmpty,
              "0.125 above 0.18, ends kept, highlights alone, splits not listed; got \(liftedCurve.value(0.125)), \(lifted.unmapped)")
        let lowered = Curve(LightroomPresets.adjustments(["ParametricHighlights": "-60"]).0.curves.master)
        check("parametric highlights lower the highlights", lowered.value(0.875) < 0.83 && abs(lowered.value(0.125) - 0.125) < 0.01,
              "0.875 below 0.83, shadows alone; got \(lowered.value(0.875)), \(lowered.value(0.125))")
        let point = "0, 0;128, 160;255, 255"
        let alone = Curve(LightroomPresets.adjustments(["ToneCurvePV2012": point]).0.curves.master).value(0.5)
        let both = Curve(LightroomPresets.adjustments(["ToneCurvePV2012": point, "ParametricLights": "+40"]).0.curves.master).value(0.5)
        check("parametric curve on top of the point curve", alone > 0.6 && both > alone + 0.03, "point 0.627, more with Lights; got \(alone), \(both)")
        let narrow = Curve(LightroomPresets.adjustments(["ParametricShadows": "+100", "ParametricShadowSplit": "10"]).0.curves.master).value(0.3)
        let wide = Curve(LightroomPresets.adjustments(["ParametricShadows": "+100", "ParametricShadowSplit": "40"]).0.curves.master).value(0.3)
        check("parametric split moves the zone", wide > narrow + 0.03, "shadows reach further with the split at 40; got \(narrow), \(wide)")
        let channel = LightroomPresets.adjustments(["ToneCurvePV2012Red": "0, 0;128, 150;255, 255"]).0.curves.red
        check("per-channel point curve", channel.count == 3 && abs(channel[1].y - 150.0 / 255) < 0.001, "red middle 0.588; got \(channel)")

        // Split toning to the wheels, only without Colour Grading; Blending and Balance.
        let split = LightroomPresets.adjustments(["SplitToningShadowHue": "120", "SplitToningShadowSaturation": "50", "SplitToningHighlightHue": "0",
                                                  "SplitToningHighlightSaturation": "100", "SplitToningBalance": "+30"])
        let w = split.0.wheels
        check("split toning to the wheels", abs(w.lift.x + 0.1) < 0.001 && abs(w.lift.y - 0.1732) < 0.001 && abs(w.gain.x - 0.4) < 0.001
              && w.balance == 30 && split.unmapped.isEmpty,
              "lift (-0.1, 0.173), gain 0.4, balance 30; got \(w.lift), \(w.gain), \(w.balance), \(split.unmapped)")
        let graded = LightroomPresets.adjustments(["SplitToningShadowHue": "120", "SplitToningShadowSaturation": "50", "ColorGradeShadowSat": "0",
                                                   "ColorGradeBlending": "80", "ColorGradeBalance": "-20"]).0.wheels
        check("colour grading wins over split toning, blending and balance", graded.lift.isDefault && graded.blending == 80 && graded.balance == -20,
              "no lift, 80, -20; got \(graded.lift), \(graded.blending), \(graded.balance)")
        // Old wheels (saved before Blending and Balance) keep their push and get Lightroom's neutral 50 and 0.
        let oldWheels = try? JSONDecoder().decode(ColorWheels.self, from: Data(#"{"lift":{"x":0.1,"y":0,"master":0},"gamma":{"x":0,"y":0,"master":0},"gain":{"x":0,"y":0,"master":0},"offset":{"x":0,"y":0,"master":0}}"#.utf8))
        check("old wheels decode", oldWheels?.lift.x == 0.1 && oldWheels?.blending == 50 && oldWheels?.balance == 0, "0.1, 50, 0; got \(String(describing: oldWheels))")
        // The engine: Balance towards the highlights warms mid grey with a warm highlights wheel; Blending widens the ranges.
        func developed(_ wheels: ColorWheels, _ grey: Float) -> SIMD3<Float> {
            var a = PhotoAdjustments()
            a.wheels = wheels
            let out = PhotoRender.adjusted(picture(8, 8) { _, _ in SIMD3(repeating: grey) }, a, isRaw: true, kelvin: 6500)
            var px = [Float](repeating: 0, count: 4)
            px.withUnsafeMutableBytes {
                PhotoEngine.context.render(out, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                                           format: .RGBAf, colorSpace: extrasSpace)
            }
            return SIMD3(px[0], px[1], px[2])
        }
        var warm = ColorWheels()
        warm.gain.x = 0.3
        var balanced = warm
        balanced.balance = 100
        let plainWarm = developed(warm, 0.18), moreWarm = developed(balanced, 0.18)
        check("grading balance moves the split", (moreWarm.x - moreWarm.z) > (plainWarm.x - plainWarm.z) + 0.005,
              "mid grey warmer with balance 100; got \(plainWarm), \(moreWarm)")
        var soft = warm
        soft.blending = 100
        var hard = warm
        hard.blending = 0
        let softer = developed(soft, 0.18), harder = developed(hard, 0.18)
        check("grading blending widens the ranges", (softer.x - softer.z) > (harder.x - harder.z) + 0.003,
              "mid grey reached by the highlights more when blended; got \(harder), \(softer)")

        // The vignette: as before at its defaults, then each shape setting.
        let grey = picture(96, 64) { _, _ in SIMD3(repeating: 0.18) }
        func vignetted(_ change: (inout PhotoAdjustments) -> Void, _ image: CIImage? = nil) -> CIImage {
            var a = PhotoAdjustments()
            a.vignette = -60
            change(&a)
            return PhotoRender.effects(image ?? grey, a, grain: true, scale: 1, origin: .zero)
        }
        let before = vignetted { _ in }
        // (Paint Overlay changes only lighter edges, so darker ones go the shaped way and must come out the same.)
        let shapedWay = vignetted { $0.vignetteStyle = 3 }
        let corners = [(0, 0), (95, 63), (48, 0), (0, 32)]
        let off = corners.map { abs(red(before, $0.0, $0.1) - red(shapedWay, $0.0, $0.1)) }.max() ?? 1
        check("vignette defaults keep the look", off < 0.002 && red(before, 0, 0) < 0.15, "same within 0.002 (and darker corners); got \(off)")
        let inward = vignetted { $0.vignetteMidpoint = 0 }, outward = vignetted { $0.vignetteMidpoint = 100 }
        check("vignette midpoint", red(inward, 20, 10) < red(outward, 20, 10) - 0.005, "reaches further in at 0; got \(red(inward, 20, 10)), \(red(outward, 20, 10))")
        let hardEdge = vignetted { $0.vignetteFeather = 0 }, softEdge = vignetted { $0.vignetteFeather = 100 }
        check("vignette feather", abs(red(hardEdge, 30, 20) - red(softEdge, 30, 20)) > 0.005, "a different edge; got \(red(hardEdge, 30, 20)), \(red(softEdge, 30, 20))")
        let frame = vignetted { $0.vignetteRoundness = 0 }
        check("vignette roundness", red(frame, 48, 0) < red(before, 48, 0) - 0.005 && abs(red(frame, 0, 32) - red(before, 0, 32)) < 0.002,
              "top middle darker with the frame's shape, left middle the same; got \(red(frame, 48, 0)), \(red(before, 48, 0))")
        let bright = picture(96, 64) { _, _ in SIMD3(repeating: 0.9) }
        let kept = vignetted({ $0.vignetteHighlights = 100 }, bright), dark = vignetted({ _ in }, bright)
        check("vignette highlights", red(kept, 0, 0) > red(dark, 0, 0) + 0.05, "bright corners keep their light; got \(red(kept, 0, 0)), \(red(dark, 0, 0))")
        let paint = vignetted({ $0.vignette = 60; $0.vignetteStyle = 3 }, bright), lighter = vignetted({ $0.vignette = 60 }, bright)
        check("vignette paint overlay", red(paint, 0, 0) <= 1.0001 && red(paint, 0, 0) < red(lighter, 0, 0) - 0.05,
              "lighter edges towards white, never past it; got \(red(paint, 0, 0)), \(red(lighter, 0, 0))")
        let shapeIn = LightroomPresets.adjustments(["PostCropVignetteAmount": "-30", "PostCropVignetteMidpoint": "30", "PostCropVignetteFeather": "70",
                                                    "PostCropVignetteRoundness": "0", "PostCropVignetteHighlights": "20", "PostCropVignetteStyle": "3"])
        let s = shapeIn.0
        let noAmount = LightroomPresets.adjustments(["PostCropVignetteAmount": "0", "PostCropVignetteRoundness": "0", "PostCropVignetteMidpoint": "30"])
        check("vignette shape from lightroom", s.vignette == -30 && s.vignetteMidpoint == 30 && s.vignetteFeather == 70 && s.vignetteRoundness == 0
              && s.vignetteHighlights == 20 && s.vignetteStyle == 3 && shapeIn.unmapped.isEmpty && noAmount.0.isDefault && noAmount.unmapped.isEmpty,
              "-30, 30, 70, 0, 20, 3; without an amount nothing; got \(s.vignette), \(s.vignetteMidpoint), \(s.vignetteFeather), \(s.vignetteRoundness), \(s.vignetteHighlights), \(s.vignetteStyle), \(noAmount.0.isDefault)")

        // Grain: on its own, the same every time, strongest in the midtones, the same size in a smaller render, none with film.
        func grained(_ image: CIImage, amount: Double = 60, size: Double = 25, scale: Double = 1) -> CIImage {
            var a = PhotoAdjustments()
            a.grain = amount; a.grainSize = size
            return PhotoRender.effects(image, a, grain: true, scale: scale, origin: image.extent.origin)
        }
        let flat = picture(128, 128) { _, _ in SIMD3(repeating: 0.18) }
        let once = reds(grained(flat)), again = reds(grained(flat))
        check("grain adds grain", spread(once) > 0.004 && Set(reds(grained(flat, amount: 0))).count == 1, "spread over 0.004, none at 0; got \(spread(once))")
        check("grain is the same every render", once == again, "pixel-exact")
        let white = picture(128, 128) { _, _ in SIMD3(repeating: 0.95) }
        check("grain follows the midtones", spread(once) / 0.18 > 3 * spread(reds(grained(white))) / 0.95,
              "relative spread at grey over 3× white's; got \(spread(once) / 0.18), \(spread(reds(grained(white))) / 0.95)")
        // A half-size render against the full one averaged down by 2: the same grain.
        let small = picture(64, 64) { _, _ in SIMD3(repeating: 0.18) }
        let full = reds(grained(flat, size: 50)), half = reds(grained(small, size: 50, scale: 0.5))
        var averaged: [Float] = []
        for y in 0..<64 { for x in 0..<64 { averaged.append((full[2 * y * 128 + 2 * x] + full[2 * y * 128 + 2 * x + 1] + full[(2 * y + 1) * 128 + 2 * x] + full[(2 * y + 1) * 128 + 2 * x + 1]) / 4) } }
        let ratio = spread(half) / max(spread(averaged), 1e-6)
        check("grain keeps its size in a smaller render", ratio > 0.7 && ratio < 1.4, "spread ratio near 1; got \(ratio)")
        var filmA = PhotoAdjustments()
        filmA.grain = 60
        let scene = PhotoRender.adjusted(flat, filmA, isRaw: true, kelvin: 6500, scene: true)
        check("grain skipped with film", spread(reds(scene)) < 1e-5, "no spread in the film's scene light; got \(spread(reds(scene)))")
        let grainIn = LightroomPresets.adjustments(["GrainAmount": "25", "GrainSize": "40", "GrainFrequency": "70"])
        let noGrain = LightroomPresets.adjustments(["GrainAmount": "0", "GrainSize": "40", "GrainFrequency": "70"])
        check("grain from lightroom", grainIn.0.grain == 25 && grainIn.0.grainSize == 40 && grainIn.0.grainRoughness == 70 && grainIn.unmapped.isEmpty
              && noGrain.0.isDefault, "25, 40, 70, nothing without an amount; got \(grainIn.0.grain), \(grainIn.0.grainSize), \(grainIn.0.grainRoughness)")

        // Process 2010: the nearest of today's sliders, and never over today's own.
        let old = LightroomPresets.adjustments(["ProcessVersion": "5.7", "Exposure": "+1.00", "Contrast": "50", "Brightness": "100", "FillLight": "30",
                                                "HighlightRecovery": "40", "Clarity": "20", "Shadows": "15"])
        let o = old.0
        check("process 2010 sliders", o.exposure == 1.5 && o.contrast == 25 && o.shadows == 30 && o.highlights == -40 && o.clarity == 20 && o.blacks == -10
              && old.unmapped.isEmpty,
              "1.5, 25, 30, -40, 20, -10; got \(o.exposure), \(o.contrast), \(o.shadows), \(o.highlights), \(o.clarity), \(o.blacks), \(old.unmapped)")
        let newer = LightroomPresets.adjustments(["ProcessVersion": "11.0", "Exposure2012": "+0.50", "Exposure": "+1.00", "Brightness": "100"]).0
        check("process 2010 sliders not over today's", newer.exposure == 0.5, "0.5; got \(newer.exposure)")

        // Saved before any of this: the defaults, so the look is kept.
        var saved = PhotoAdjustments()
        saved.vignette = -20
        saved.process = 2
        let json = (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(saved)) ?? Data())) as? [String: Any] ?? [:]
        let stripped = json.filter { !$0.key.hasPrefix("vignette") || $0.key == "vignette" }.filter { !$0.key.hasPrefix("grain") }
        let back = (try? JSONSerialization.data(withJSONObject: stripped)).flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }
        check("old settings without the new fields decode", back == saved, "the same as saved; got \(String(describing: back))")
    }
}
