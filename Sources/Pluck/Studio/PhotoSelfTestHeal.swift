import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Spot heal and clone (-PluckScreenshotOnly heal): no spots change nothing (render, saved settings, preview key), clone
/// copies, heal blends a blemish away, old settings read, spots are saved and undone like any edit and left out of paste.
extension PhotoSelfTest {
    static func heal() async {
        let context = PhotoEngine.context
        let square = CGRect(x: 0, y: 0, width: 256, height: 256)
        // (Colours in linear light, as the decode is: CIColor(red:green:blue:) alone is sRGB, 0.5 reads as 0.21.)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIColor { CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linear)! }
        func grey(_ v: CGFloat) -> CIImage { CIImage(color: colour(v, v, v)).cropped(to: square) }
        func disc(_ c: CGPoint, _ r: CGFloat, _ colour: CIColor, over image: CIImage) -> CIImage {
            let g = CIFilter.radialGradient()
            g.center = c; g.radius0 = Float(r); g.radius1 = Float(r + 0.5)
            g.color0 = colour; g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            return g.outputImage!.cropped(to: square).composited(over: image)
        }
        func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> SIMD3<Float> {
            var p = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return SIMD3(p[0], p[1], p[2])
        }
        func bytes(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: 256 * 256 * 4)
            context.render(image, toBitmap: &p, rowBytes: 256 * 16, bounds: square, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            return p
        }

        // No spots: the same render, the same saved settings, the same preview key.
        let ramp = CIFilter.linearGradient()
        ramp.point0 = .zero; ramp.point1 = CGPoint(x: 256, y: 256)
        ramp.color0 = CIColor(red: 0.05, green: 0.1, blue: 0.2); ramp.color1 = CIColor(red: 0.9, green: 0.7, blue: 0.4)
        let picture = ramp.outputImage!.cropped(to: square)
        var plain = PhotoAdjustments()
        plain.exposure = 0.4; plain.contrast = 20
        var emptied = plain
        emptied.spots = []
        check("heal: an empty list is none", emptied.spots == nil && emptied == plain, "nil; got \(String(describing: emptied.spots))")
        check("heal: no spots, the same image", PhotoHeal.apply(nil, to: picture) === picture && PhotoHeal.apply([], to: picture) === picture)
        let one = bytes(PhotoRender.adjusted(picture, plain, isRaw: false, kelvin: 6500))
        let two = bytes(PhotoRender.adjusted(picture, emptied, isRaw: false, kelvin: 6500))
        check("heal: no spots, the same render", one == two, "renders differ")
        let saved = (try? JSONEncoder().encode(plain)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("heal: no spots, nothing saved", !saved.contains("spots") && (try? JSONEncoder().encode(emptied)) == (try? JSONEncoder().encode(plain)), saved)
        var record = PhotoRecord(), recordEmptied = PhotoRecord()
        record.adjust = plain; recordEmptied.adjust = emptied
        check("heal: no spots, the same preview key",
              PhotoRender.cachedPreview("/tmp/pluck-selftest/heal.jpg", record: record) == PhotoRender.cachedPreview("/tmp/pluck-selftest/heal.jpg", record: recordEmptied))
        check("heal: no spots, the same layer key", PhotoHeal.key("k", nil) == "k" && PhotoHeal.key("k", []) == "k")

        // Bitmaps read from the top (what the source finder counts on).
        let halves = grey(0.8).cropped(to: CGRect(x: 0, y: 128, width: 256, height: 128)).composited(over: grey(0.2))
        var rows = [Float](repeating: 0, count: 256 * 256 * 4)
        context.render(halves, toBitmap: &rows, rowBytes: 256 * 16, bounds: square, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        check("heal: bitmap rows from the top", rows[0] > 0.7 && rows[(255 * 256) * 4] < 0.3, "top \(rows[0]), bottom \(rows[(255 * 256) * 4])")

        // Clone: the source's red disc lands in the target's middle; outside the circle nothing changes.
        let red = disc(CGPoint(x: 192, y: 128), 20, colour(1, 0, 0), over: grey(0.5))
        let clone = PhotoSpot(kind: .clone, centre: CGPoint(x: 0.25, y: 0.5), source: CGPoint(x: 0.75, y: 0.5), radius: 0.05, feather: 0, opacity: 1)
        let cloned = PhotoHeal.apply([clone], to: red)
        let middle = pixel(cloned, 64, 128), outside = pixel(cloned, 64, 170)
        check("heal: clone copies the source", middle.x > 0.95 && middle.y < 0.05 && abs(outside.x - 0.5) < 0.01, "red then grey; got \(middle), \(outside)")
        check("heal: clone keeps the size", cloned.extent == square, "\(cloned.extent)")

        // Heal: a dark blemish on flat grey comes back near the grey (source found automatically, clear of it).
        let blemish = disc(CGPoint(x: 77, y: 128), 6, colour(0.05, 0.05, 0.05), over: grey(0.5))
        let at = CGPoint(x: 0.3, y: 0.5)
        let source = PhotoHeal.findSource(blemish, centre: at, radius: 0.05)
        let apart = hypot((source.x - at.x) * 256, (source.y - at.y) * 256) / (0.05 * 256)
        check("heal: source found nearby, inside the photo", apart >= 1.4 && apart <= 3.1 && (0...1).contains(source.x) && (0...1).contains(source.y),
              "1.5–3 radii; got \(apart) at \(source)")
        let healed = PhotoHeal.apply([PhotoSpot(kind: .heal, centre: at, source: source, radius: 0.05, feather: 0.5, opacity: 1)], to: blemish)
        let before = pixel(blemish, 77, 128), after = pixel(healed, 77, 128)
        check("heal: a blemish heals to the grey", before.x < 0.1 && abs(after.x - 0.5) < 0.03, "0.05 → 0.5; got \(before.x) → \(after.x)")
        // On a brighter patch the heal takes the target's grey, not the source's.
        let lighter = disc(CGPoint(x: 77, y: 128), 6, colour(0.05, 0.05, 0.05),
                           over: grey(0.7).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 256)).composited(over: grey(0.3)))
        let matched = PhotoHeal.apply([PhotoSpot(kind: .heal, centre: at, source: CGPoint(x: 0.8, y: 0.5), radius: 0.05)], to: lighter)
        let m = pixel(matched, 77, 128)
        check("heal: matches the target's light", abs(m.x - 0.7) < 0.04, "0.7 (the target's), not 0.3 (the source's); got \(m.x)")
        let rendered = bytes(PhotoRender.adjusted(blemish, { var a = PhotoAdjustments(); a.spots = [PhotoSpot(kind: .heal, centre: at, source: source)]; return a }(),
                                                  isRaw: false, kelvin: 6500))
        let untouched = bytes(PhotoRender.adjusted(blemish, PhotoAdjustments(), isRaw: false, kelvin: 6500))
        check("heal: spots reach the render", rendered != untouched)

        // Old settings (no spots) read; spots are saved, read back, undone, and left out of a paste.
        let old = #"{"exposure":0.5,"contrast":10,"process":6,"masks":[]}"#
        let read = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(old.utf8))
        check("heal: old settings read", read?.exposure == 0.5 && read?.contrast == 10 && read?.spots == nil, "\(String(describing: read))")
        let path = "/tmp/pluck-selftest/heal-\(UUID().uuidString).jpg"
        let spot = PhotoSpot(kind: .clone, centre: CGPoint(x: 0.2, y: 0.3), source: CGPoint(x: 0.4, y: 0.3), radius: 0.03, feather: 0.2, opacity: 0.8)
        let catalog = PhotoCatalog.shared
        catalog.endStep()
        catalog.update([path]) { $0.adjust.exposure = 0.25 }
        catalog.endStep()
        PhotoHeal.change(path) { $0.append(spot) }
        catalog.endStep()
        catalog.saveNow()
        let back = PhotoCatalog.readFile()?[path]
        check("heal: spots saved and read back", back?.adjust.spots == [spot], "\(String(describing: back?.adjust.spots))")
        catalog.undo()
        check("heal: a spot is one undo step", catalog.record(path).adjust.spots == nil && catalog.record(path).adjust.exposure == 0.25,
              "\(String(describing: catalog.record(path).adjust.spots))")
        catalog.redo()
        check("heal: redo brings it back", catalog.record(path).adjust.spots == [spot])
        let other = "/tmp/pluck-selftest/heal-other-\(UUID().uuidString).jpg"
        PhotoPasteboard.copy(path)
        PhotoPasteboard.paste(PasteGroup.chosen, to: [other])
        check("heal: paste leaves spots out", catalog.record(other).adjust.spots == nil && catalog.record(other).adjust.exposure == 0.25,
              "\(String(describing: catalog.record(other).adjust.spots))")
        PhotoPasteboard.paste([.spots], to: [other])
        check("heal: Spot Heal pastes when chosen", catalog.record(other).adjust.spots == [spot])
    }
}
