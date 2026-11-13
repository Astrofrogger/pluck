import CoreImage
import simd
import Foundation

/// Lens corrections (-PluckScreenshotOnly lens): untouched changes nothing (render, saved settings, preview key), Distortion
/// straightens a barrel-distorted line (and keeps the frame filled), Vignetting brightens the corners and not the middle, the
/// fringe sliders move red and blue edges by the expected pixels, Remove fringes takes a purple fringe out and leaves a purple
/// area be, and the settings are saved, undone, found and pasted with the crop.
extension PhotoSelfTest {
    static func lens() async {
        let context = PhotoEngine.context
        func floats(_ image: CIImage, _ bounds: CGRect) -> [Float] {
            var p = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
            context.render(image, toBitmap: &p, rowBytes: Int(bounds.width) * 16, bounds: bounds, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return p
        }
        let w = 900.0, h = 600.0
        let frame = CGRect(x: 0, y: 0, width: w, height: h)

        // Untouched: the same render, the same saved settings, the same preview key.
        let ramp = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: w, y: h),
                                                                   "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3), "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.5)])!
            .outputImage!.cropped(to: frame)
        var plain = PhotoAdjustments()
        plain.exposure = 0.3; plain.straighten = 2
        var zeroed = plain
        zeroed.lens = PhotoLens()
        check("lens: untouched is none", zeroed.lens == nil && zeroed == plain, "\(String(describing: zeroed.lens))")
        check("lens: untouched, the same render",
              floats(PhotoRender.adjusted(ramp, plain, isRaw: false, kelvin: 6500), frame) == floats(PhotoRender.adjusted(ramp, zeroed, isRaw: false, kelvin: 6500), frame))
        // (Sorted keys: JSONEncoder's key order differs from one encode to the next, measured, so unsorted bytes can't be compared.)
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        let saved = (try? sorted.encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("lens: untouched, nothing saved", !saved.contains("\"lens\"") && (try? sorted.encode(zeroed)) == (try? sorted.encode(plain)), saved)
        // (The preview key is the encoded edit: the same settings and the same sorted bytes give the same key.)
        check("lens: untouched, the same preview key", zeroed == plain && (try? sorted.encode(zeroed)) == (try? sorted.encode(plain)))
        let old = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.5,"straighten":1.5,"process":6,"masks":[]}"#.utf8))
        check("lens: old settings read", old?.straighten == 1.5 && old?.lens == nil, "\(String(describing: old))")
        // (A PhotoLens is made whole, then set: a default one set first is nil, and `lens?.x =` on nil does nothing.)
        var wired = plain, vignetted = PhotoLens()
        vignetted.vignetting = 40
        wired.lens = vignetted
        check("lens: in the render", floats(PhotoRender.adjusted(ramp, wired, isRaw: false, kelvin: 6500), frame)
              != floats(PhotoRender.adjusted(ramp, plain, isRaw: false, kelvin: 6500), frame))

        // Distortion: a line 180 px above the middle, bent by barrel distortion (the world at radius r(1 + 0.1 r²), r a share
        // of the half diagonal), is straightened by + (about 50 matches it) and bent more by −.
        let barrel = CIColorKernel(source: """
            kernel vec4 barrel(__sample s, vec2 centre, float reach, float c, float y0) {
                vec2 p = (destCoord() - centre) / reach;
                vec2 u = p * (1.0 + c * dot(p, p));
                float ink = 1.0 - smoothstep(1.0, 2.5, abs(u.y * reach - y0));
                return vec4(vec3(0.8 - 0.7 * ink), 1.0);
            }
            """)
        let bent = barrel?.apply(extent: frame, arguments: [CIImage(color: .white).cropped(to: frame), CIVector(x: w / 2, y: h / 2),
                                                             hypot(w, h) / 2, 0.1, 180.0]) ?? CIImage(color: .white).cropped(to: frame)
        // How far the line wanders up and down across the frame (its darkness's centre in each column; the only line).
        func bow(_ image: CIImage) -> Double {
            let p = floats(image, frame)
            var ys: [Double] = []
            for x in stride(from: 45, to: Int(w) - 45, by: 30) {
                var sum = 0.0, weight = 0.0
                for y in 0..<Int(h) {
                    let ink = max(0.8 - Double(p[(y * Int(w) + x) * 4 + 1]), 0)
                    sum += ink * Double(y); weight += ink
                }
                if weight > 0 { ys.append(sum / weight) }
            }
            return (ys.max() ?? 0) - (ys.min() ?? 99)
        }
        func corrected(_ d: Double) -> CIImage {
            var a = PhotoAdjustments(), l = PhotoLens()
            l.distortion = d
            a.lens = l
            return PhotoRender.geometry(bent, a)
        }
        // (The slider's scale is a choice: some positive value must straighten it, wherever it lands.)
        let before = bow(bent), minus = bow(corrected(-50))
        let best = stride(from: 10.0, through: 100, by: 10).map { ($0, bow(corrected($0))) }.min { $0.1 < $1.1 }!
        let plus = best.1
        check("lens: Distortion straightens barrel", before > 5 && plus < before * 0.25, "bow \(before) px → under a quarter; best at +\(Int(best.0)): \(plus)")
        check("lens: Distortion the other way bends it more", minus > before * 1.5, "bow \(before) → more; got \(minus)")
        for d in [100.0, -100.0] {
            var a = PhotoAdjustments(), l = PhotoLens()
            l.distortion = d
            a.lens = l
            let warped = PhotoRender.geometry(CIImage(color: .white).cropped(to: frame), a)
            let p = floats(warped, frame)
            let W = Int(w), H = Int(h)
            let spots: [Int] = [0, W - 1, W * (H - 1), W * H - 1, (H / 2) * W, W / 2]
            let corners = spots.map { p[$0 * 4 + 3] }
            check("lens: Distortion \(Int(d)) leaves no empty edges", warped.extent == frame && corners.allSatisfy { $0 > 0.99 },
                  "alpha 1 at \(frame); got \(corners) at \(warped.extent)")
        }

        // Vignetting: a flat grey's middle unchanged, its corners a stop brighter at 50 (two at 100); Midpoint lower reaches in.
        let grey = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: frame)
        func shade(_ v: Double, _ m: Double) -> [Float] {
            var l = PhotoLens()
            l.vignetting = v; l.midpoint = m
            return floats(PhotoLens.shaded(l, grey), frame)
        }
        let flat = floats(grey, frame)
        let centre = (Int(h / 2) * Int(w) + Int(w / 2)) * 4, corner = 0, half = (Int(h / 2) * Int(w) + Int(w * 0.8)) * 4
        let lifted = shade(50, 50), wider = shade(50, 10)
        check("lens: Vignetting leaves the middle", abs(lifted[centre] - flat[centre]) < 1e-3, "\(flat[centre]); got \(lifted[centre])")
        check("lens: Vignetting brightens the corners", abs(lifted[corner] / flat[corner] - 2) < 0.08, "about 2×; got \(lifted[corner] / flat[corner])")
        check("lens: Midpoint lower reaches further in", wider[half] > lifted[half] * 1.05, "\(lifted[half]) → more; got \(wider[half])")
        check("lens: negative Vignetting darkens the corners", shade(-50, 50)[corner] < flat[corner] * 0.55)

        // Fringes: on a 3000 × 2000 frame, a dark-to-white edge 1200 px right of the middle; Red/Cyan 100 moves red out by
        // 0.2% of that (about 2.4 px), Blue/Yellow −50 moves blue in by 0.1% (about 1.2 px), green stays.
        let big = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let edge = CIImage(color: .white).cropped(to: CGRect(x: 2700, y: 0, width: 300, height: 2000))
            .composited(over: CIImage(color: .black).cropped(to: big))
        var fringe = PhotoLens()
        fringe.redCyan = 100; fringe.blueYellow = -50
        let row = CGRect(x: 2600, y: 1000, width: 200, height: 1)
        let line = floats(PhotoLens.shaded(fringe, edge), row)
        func at(_ channel: Int) -> Double { 2600 + (0..<200).reduce(0.0) { $0 + 1 - min(max(Double(line[$1 * 4 + channel]), 0), 1) } }
        let red = at(0) - at(1), blue = at(2) - at(1)
        let wantRed = 1200 / (1 + fringe.redScale) - 1200, wantBlue = 1200 / (1 + fringe.blueScale) - 1200
        check("lens: green edge stays", abs(at(1) - 2700) < 0.05, "2700; got \(at(1))")
        check("lens: Red/Cyan moves red", abs(red - wantRed) < 0.3, "\(wantRed) px; got \(red)")
        check("lens: Blue/Yellow moves blue", abs(blue - wantBlue) < 0.3, "\(wantBlue) px; got \(blue)")

        // Remove fringes: a purple column beside a black-to-white edge loses most of its colour; a purple area keeps it all.
        let small = CGRect(x: 0, y: 0, width: 400, height: 200)
        let purple = CIColor(red: 0.5, green: 0.15, blue: 0.6)
        let fringed = CIImage(color: .white).cropped(to: CGRect(x: 202, y: 0, width: 198, height: 200))
            .composited(over: CIImage(color: purple).cropped(to: CGRect(x: 200, y: 0, width: 2, height: 200)))
            .composited(over: CIImage(color: .black).cropped(to: small))
        var clean = PhotoLens()
        clean.defringe = true
        func chroma(_ p: [Float], _ i: Int) -> Double {
            let c = (0..<3).map { Double(p[i * 4 + $0]) }
            return (c.max()! - c.min()!) / max(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2], 1e-6)
        }
        let i = 100 * 400 + 200
        let was = chroma(floats(fringed, small), i), now = chroma(floats(PhotoLens.shaded(clean, fringed), small), i)
        check("lens: Remove fringes takes the fringe out", now < was * 0.5, "\(was) → under half; got \(now)")
        let area = CIImage(color: purple).cropped(to: small)
        // (Within the half-float intermediate's rounding: the kernel's weight is exactly 0 there.)
        let kept = floats(PhotoLens.shaded(clean, area), small), raw = floats(area, small)
        let drift = zip(kept, raw).map { abs($0 - $1) / max(abs($1), 1e-3) }.max() ?? 1
        check("lens: Remove fringes leaves a purple area", drift < 2e-3, "unchanged; got \(drift) at most")

        // Found by its words; the section edited and reset.
        check("lens: found", ["lens", "distortion", "vignette", "fringe"].allSatisfy { AdjustSection.lens.matches($0) })
        var reset = wired
        check("lens: the section is edited", AdjustSection.lens.isEdited(reset))
        AdjustSection.lens.reset(&reset)
        check("lens: the section resets", reset.lens == nil && !AdjustSection.lens.isEdited(reset))

        // Saved and read back, one undo step, and pasted with the crop (not without it).
        let path = "/tmp/pluck-selftest/lens-\(UUID().uuidString).jpg"
        let catalog = PhotoCatalog.shared
        var set = PhotoLens()
        set.distortion = 18; set.vignetting = 30; set.midpoint = 35; set.redCyan = -12; set.blueYellow = 8; set.defringe = true
        catalog.endStep()
        catalog.update([path]) { $0.adjust.exposure = 0.25 }
        catalog.endStep()
        catalog.update([path]) { $0.adjust.lens = set }
        catalog.endStep()
        catalog.saveNow()
        let back = PhotoCatalog.readFile()?[path]
        check("lens: saved and read back", back?.adjust.lens == set, "\(String(describing: back?.adjust.lens))")
        catalog.undo()
        check("lens: one undo step", catalog.record(path).adjust.lens == nil && catalog.record(path).adjust.exposure == 0.25)
        catalog.redo()
        let target = "/tmp/pluck-selftest/lens-other-\(UUID().uuidString).jpg"
        PhotoPasteboard.copy(path)
        PhotoPasteboard.paste(PasteGroup.chosen.subtracting([.crop]), to: [target])
        check("lens: left out of a paste without the crop", catalog.record(target).adjust.lens == nil)
        PhotoPasteboard.paste([.crop], to: [target])
        check("lens: pasted with the crop", catalog.record(target).adjust.lens == set)

        // Drawn in bands (the full size when zoomed in) as at once: a distorted picture's bands each show their own rows.
        var banding = PhotoAdjustments(); banding.lens = PhotoLens(); banding.lens?.distortion = 27; banding.lens?.profileK2 = -0.02
        let tall = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: 2000),
                                                                   "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
            .cropped(to: CGRect(x: 0, y: 0, width: 1500, height: 2000))
        let whole = PhotoRender.geometry(tall, banding)
        if let banded = BaseCache.texture(whole, bands: 1500 * 300) {
            func row(_ i: CIImage, _ y: CGFloat) -> Float {
                var p = [Float](repeating: 0, count: 4)
                let e = i.extent
                PhotoEngine.context.render(i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: e.midX - 50, y: e.minY + y * e.height, width: 100, height: 4))]),
                                           toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return p[0]
            }
            let pairs = [0.1, 0.3, 0.5, 0.7, 0.9].map { (row(whole, $0), row(banded, $0)) }
            check("lens: drawn in bands as at once", pairs.allSatisfy { abs($0.0 - $0.1) < 0.02 }, "\(pairs)")
        } else { check("lens: drawn in bands", false, "no texture") }

        // The owner's case: a RAW with a profile's lens settings and a slight straighten, at full size (zoomed in) as in a preview.
        let owner = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("raws/DSC01994.ARW").path
        if FileManager.default.fileExists(atPath: owner) {
            var record = PhotoRecord()
            record.adjust.lens = PhotoLens(); record.adjust.lens?.distortion = 27; record.adjust.lens?.vignetting = 100; record.adjust.lens?.midpoint = 20
            record.adjust.lens?.redCyan = -5; record.adjust.lens?.defringe = true; record.adjust.lens?.profileK2 = -0.02
            record.adjust.straighten = -1.5
            if let full = PhotoRender.image(owner, record: record, maxSize: 0), let small = PhotoRender.image(owner, record: record, maxSize: 1400) {
                func row(_ i: CIImage, _ y: CGFloat) -> SIMD3<Float> {
                    var p = [Float](repeating: 0, count: 4)
                    let e = i.extent
                    PhotoEngine.context.render(i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: e.minX + e.width * 0.3, y: e.minY + y * e.height, width: e.width * 0.4, height: e.height * 0.02))]),
                                               toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    return SIMD3(p[0], p[1], p[2])
                }
                let rows = [0.1, 0.3, 0.6, 0.85].map { (row(full, $0), row(small, $0)) }
                check("lens: zoomed in as the preview", rows.allSatisfy { simd_length($0.0 - $0.1) < 0.05 }, "full \(full.extent), small \(small.extent): \(rows.map { "\($0.0.x)/\($0.1.x)" })")
            } else { check("lens: zoomed in", false, "no picture") }
        }

        // Apple's lens correction switched off: its own decode (a different cache key) and a different picture at the edges.
        let viltrox = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("raws/DSC01994.ARW").path
        if FileManager.default.fileExists(atPath: viltrox) {
            var off = PhotoRecord(); var offLens = PhotoLens(); offLens.appleOff = true; off.adjust.lens = offLens
            check("lens: Apple's correction off has its own decode", PhotoRender.RawSettings(off.adjust).key != PhotoRender.RawSettings(PhotoRecord().adjust).key)
            if let a = PhotoRender.decoded(viltrox, maxSize: 1200, record: PhotoRecord()), let b = PhotoRender.decoded(viltrox, maxSize: 1200, record: off) {
                func corner(_ i: CIImage) -> Float {
                    var p = [Float](repeating: 0, count: 4)
                    let e = i.extent
                    PhotoEngine.context.render(i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: e.minX + 4, y: e.minY + 4, width: e.width * 0.08, height: e.height * 0.08))]),
                                               toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                    return p[1]
                }
                check("lens: Apple's correction off changes the corners", abs(corner(a) - corner(b)) / max(corner(a), 1e-5) > 0.01, "on \(corner(a)), off \(corner(b))")
            }
        }
    }
}