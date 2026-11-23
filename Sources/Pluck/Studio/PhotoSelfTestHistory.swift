import CoreImage
import Foundation
import simd

/// History (-PluckScreenshotOnly history): a photo's changes are listed as named steps; going back to one sets the photo as it
/// was then, as a change of its own that can be undone.
extension PhotoSelfTest {
    static func historyTest() async {
        let catalog = PhotoCatalog.shared
        // (A new photo each run: the test catalogue and its History.json stay between runs.)
        let path = "/tmp/pluck-history/test-\(UUID().uuidString).jpg"
        catalog.endStep(); catalog.update([path]) { $0.adjust.exposure = 0.4 }
        catalog.endStep(); catalog.update([path]) { $0.adjust.masks = [PhotoMask(part: MaskPart(kind: .subject))] }
        catalog.endStep(); catalog.update([path]) { $0.rating = 3 }
        catalog.endStep()
        let steps = catalog.history(of: path)
        check("history: three steps", steps.count == 3, "\(steps.count)")
        let names = steps.map { PhotoHistory.describe($0.before, $0.after) }
        check("history: named by what changed", names.count == 3 && names[0].contains("Exposure") && names[0].contains("+0.40") && names[1].contains("Masks") && names[2].contains("Rating"),
              "\(names)")
        // Back to the first step: exposure kept, the mask and rating gone.
        if let first = steps.first?.after {
            catalog.endStep(); catalog.update([path]) { $0 = first ?? PhotoRecord() }; catalog.endStep()
            let now = catalog.record(path)
            check("history: back to a step", now.adjust.exposure == 0.4 && now.adjust.masks.isEmpty && now.rating == 0, "exposure \(now.adjust.exposure), masks \(now.adjust.masks.count), rating \(now.rating)")
            catalog.undo()
            check("history: going back can be undone", catalog.record(path).rating == 3, "rating \(catalog.record(path).rating)")
        }
        // After a restart: the done steps are still there (the undone one isn't), named the same, and none undone.
        catalog.saveNow()
        catalog.reloadHistory()
        let again = catalog.history(of: path)
        let folder = PhotoCatalog.historyFile.deletingLastPathComponent()
        check("history: kept compressed", FileManager.default.fileExists(atPath: PhotoCatalog.historyFile.path)
              && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("History.json").path), folder.path)
        // A photo's previews of earlier edits go when a newer one is saved; another photo's stay.
        do {
            var a = PhotoRecord(); a.adjust.exposure = 0.1
            var b = a; b.adjust.exposure = 0.2
            // (The photos must be there: a photo whose drive is away keeps its last preview, whatever the edit.)
            try? FileManager.default.createDirectory(atPath: "/tmp/pluck-history", withIntermediateDirectories: true)
            for name in ["p.jpg", "q.jpg"] { FileManager.default.createFile(atPath: "/tmp/pluck-history/" + name, contents: Data([1])) }
            let old = PhotoRender.cachedPreview("/tmp/pluck-history/p.jpg", record: a), new = PhotoRender.cachedPreview("/tmp/pluck-history/p.jpg", record: b)
            let other = PhotoRender.cachedPreview("/tmp/pluck-history/q.jpg", record: a)
            try? FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            for url in [old, PhotoPreviewBuilder.screenFile(old), other] { FileManager.default.createFile(atPath: url.path, contents: Data([1])) }
            if let tiny = CGImage.solid() { PhotoRender.savePreview(tiny, to: new) }
            let exists = { (u: URL) in FileManager.default.fileExists(atPath: u.path) }
            check("previews: older ones of the photo go", !exists(old) && !exists(PhotoPreviewBuilder.screenFile(old)) && exists(new) && exists(other))
            for url in [new, other] { try? FileManager.default.removeItem(at: url) }
        }
        check("history: kept after a restart", again.count == 3 && !again.contains(where: \.undone)
              && PhotoHistory.describe(again[0].before, again[0].after).contains("Exposure"), "\(again.count)")
    }
}

extension PhotoSelfTest {
    /// Red eye and pet eye (-PluckScreenshotOnly eyes): a red pupil loses its red (a dark, neutral pupil), a glowing pupil goes
    /// dark with a catch-light, and outside the circle nothing changes.
    static func eyesTest() async {
        let context = PhotoEngine.context, linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        func disc(_ c: CGPoint, _ r: CGFloat, _ colour: CIColor, over i: CIImage) -> CIImage {
            let g = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(cgPoint: c), "inputRadius0": r, "inputRadius1": r + 0.5,
                                                                    "inputColor0": colour, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
            return g.cropped(to: frame).composited(over: i)
        }
        let skin = CIImage(color: CIColor(red: 0.45, green: 0.3, blue: 0.22, alpha: 1, colorSpace: linear)!).cropped(to: frame)
        let red = disc(CGPoint(x: 200, y: 150), 12, CIColor(red: 0.6, green: 0.05, blue: 0.05, alpha: 1, colorSpace: linear)!, over: skin)
        let glow = disc(CGPoint(x: 200, y: 150), 12, CIColor(red: 0.5, green: 0.9, blue: 0.4, alpha: 1, colorSpace: linear)!, over: skin)
        func at(_ i: CIImage, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 3) -> SIMD3<Float> {
            var p = [Float](repeating: 0, count: 4)
            context.render(i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))]),
                           toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            return SIMD3(p[0], p[1], p[2])
        }
        // (Shares from the top left: the eye at (0.5, 0.5), its circle 16 px of the 400 px long side.)
        let r = 16.0 / 400
        let fixedRed = PhotoHeal.apply([PhotoSpot(kind: .redEye, centre: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 0.5), radius: r)], to: red)
        let pupil = at(fixedRed, 200, 150)
        check("eyes: red eye loses its red", pupil.x < 0.12 && pupil.x <= max(pupil.y, pupil.z) * 1.4, "\(pupil)")
        check("eyes: outside the circle unchanged", simd_length(at(fixedRed, 60, 60) - at(red, 60, 60)) < 1e-4)
        let fixedPet = PhotoHeal.apply([PhotoSpot(kind: .petEye, centre: CGPoint(x: 0.5, y: 0.5), source: CGPoint(x: 0.5, y: 0.5), radius: r)], to: glow)
        let dark = at(fixedPet, 203, 146, 2), light = at(fixedPet, 200 - 0.3 * 16, 150 + 0.3 * 16, 1)
        check("eyes: a glowing eye goes dark", dark.max() < 0.08, "\(dark)")
        check("eyes: with a catch-light", light.max() > 0.3, "\(light)")
    }

    /// Adaptive presets: masks found again on each photo are kept, what was painted on one photo isn't.
    static func adaptiveTest() async {
        var a = PhotoAdjustments()
        var sky = PhotoMask(kind: .subject); sky.parts = [MaskPart(kind: .sky)]; sky.exposure = -0.5
        var brushed = PhotoMask(kind: .subject); brushed.parts = [MaskPart(kind: .brush)]
        var mixed = PhotoMask(kind: .subject); mixed.parts = [MaskPart(kind: .subject), MaskPart(kind: .brush), MaskPart(kind: .object)]
        a.masks = [sky, brushed, mixed]
        let kept = PhotoPreset.adaptive(a).masks
        check("adaptive: sky mask kept", kept.first?.parts.map(\.kind) == [.sky] && kept.first?.exposure == -0.5)
        check("adaptive: brush-only mask left out", kept.count == 2, "\(kept.count)")
        check("adaptive: painted parts left out", kept.last?.parts.map(\.kind) == [.subject], "\(kept.last?.parts.map(\.kind) ?? [])")
    }
}

private extension CGImage {
    /// A 4 × 4 grey picture (tests).
    static func solid() -> CGImage? {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(gray: 0.5, alpha: 1); context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context?.makeImage()
    }
}
