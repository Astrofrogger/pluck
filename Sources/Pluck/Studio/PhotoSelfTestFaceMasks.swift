import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Face-part masks (-PluckScreenshotOnly facemasks): old catalogues read and save byte for byte as before; with a photo
/// that has a face (the first in -PluckScreenshotPhotos that does), each part is found, lies in its face (or person),
/// eyes and lips stay out of the face skin, one person is part of everyone, and a half-size picture gives the same masks.
extension PhotoSelfTest {
    static func faceMasks() async {
        // Old catalogue: read, saved again the same, and no new key.
        let old = #"{"exposure":0.5,"process":6,"masks":[{"id":"6F1C3E64-1B0A-4C1F-9F57-3D2C5B8A9E01","kind":"subject","parts":[{"id":"0B8E2F4A-7C6D-4E3B-A2F1-9D8C7B6A5E40","kind":"radial","mode":"add","a":[0.5,0.5]}],"exposure":0.3}]}"#
        let read = try? JSONDecoder().decode(PhotoAdjustments.self, from: Data(old.utf8))
        let once = read.flatMap { try? JSONEncoder().encode($0) }
        let twice = once.flatMap { try? JSONDecoder().decode(PhotoAdjustments.self, from: $0) }.flatMap { try? JSONEncoder().encode($0) }
        check("face masks: old catalogue reads", read?.masks.first?.parts.first?.kind == .radial && read?.masks.first?.parts.first?.person == nil)
        check("face masks: old catalogue saves the same", once != nil && once == twice && !String(decoding: once ?? Data(), as: UTF8.self).contains("person"),
              String(decoding: once ?? Data(), as: UTF8.self))
        var every = PhotoAdjustments()
        every.masks = MaskPart.Kind.allCases.filter { !$0.isFace }.map { PhotoMask(part: MaskPart(kind: $0)) }
        let plain = (try? JSONEncoder().encode(every)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("face masks: older kinds save no person", !plain.isEmpty && !plain.contains("person"))
        var chosen = MaskPart(kind: .eyes)
        chosen.person = 1
        let back = (try? JSONEncoder().encode(chosen)).flatMap { try? JSONDecoder().decode(MaskPart.self, from: $0) }
        check("face masks: a person is saved", back == chosen, "\(String(describing: back))")
        let unknown = try? JSONDecoder().decode(MaskPart.self, from: Data(#"{"kind":"lips","person":2}"#.utf8))
        check("face masks: a face part reads", unknown?.kind == .lips && unknown?.person == 2)

        // A photo with a face.
        let context = PhotoEngine.context
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: photos)) ?? []).sorted()
            .filter { ["jpg", "jpeg", "png", "heic", "tif", "tiff"].contains(($0 as NSString).pathExtension.lowercased()) }.prefix(60)
        var found: (name: String, image: CIImage, scan: PhotoMasks.FaceScan)?
        let debug = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("facemasks-debug")
        try? FileManager.default.createDirectory(at: debug, withIntermediateDirectories: true)
        for name in files {
            guard let source = CIImage(contentsOf: URL(fileURLWithPath: photos).appendingPathComponent(name), options: [.applyOrientationProperty: true])
            else { continue }
            let e = source.extent, k = min(1, 1024 / max(e.width, e.height))
            let image = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
            guard let scan = PhotoMasks.scanFaces(image, context: context), !scan.faces.isEmpty else { continue }
            if found == nil { found = (name, image, scan) }
            faceDebug(name, image: image, scan: scan, into: debug, context: context)
        }
        guard let found else { return skip("face masks: parts", "no photo with a face in \(photos)") }
        let scan = found.scan, w = scan.width, h = scan.height
        note("face masks: \(found.name), \(scan.faces.count) face(s), \(w)×\(h)")
        func values(_ image: CIImage) -> [Float] {
            var p = [Float](repeating: 0, count: w * h)
            context.render(image, toBitmap: &p, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .Lf, colorSpace: nil)
            return p
        }
        // Boxes in rows from the top: the faces (with room for the forehead) and the person.
        func inBox(_ box: CGRect) -> (Int, Int) -> Bool { { x, y in box.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h - y) - 0.5)) } }
        let faceBoxes = scan.faces.map { $0.box.insetBy(dx: -$0.box.width * 0.3, dy: -$0.box.height * 0.3).offsetBy(dx: 0, dy: $0.box.height * 0.25) }
        var personBox = CGRect.null
        for y in 0..<h { for x in 0..<w where scan.people[y * w + x] > 0.5 { personBox = personBox.union(CGRect(x: x, y: h - 1 - y, width: 1, height: 1)) } }
        personBox = personBox.insetBy(dx: -CGFloat(w) * 0.02, dy: -CGFloat(h) * 0.02)
        let half = PhotoMasks.scanFaces(found.image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)), context: context)

        let kinds: [MaskPart.Kind] = [.face, .faceSkin, .bodySkin, .eyes, .brows, .lips, .teeth, .hair]
        var planes: [MaskPart.Kind: [Float]] = [:]
        for kind in kinds {
            let p = values(PhotoMasks.faceMask(kind, person: nil, in: scan, context: context))
            planes[kind] = p
            let total = p.reduce(0, +)
            let name = "face masks: \(kind.rawValue)"
            // Teeth, body skin and hair can truly be missing (a closed mouth, a headshot, no hair): noted, not failed.
            if total < 20 {
                if [.teeth, .bodySkin, .hair].contains(kind) { note("\(name) is empty in this photo") } else { check("\(name) found", false, "empty") }
                continue
            }
            check("\(name) found", true)
            let box = [.bodySkin, .hair].contains(kind) ? inBox(personBox) : { x, y in faceBoxes.contains { inBox($0)(x, y) } }
            var inside: Float = 0
            for y in 0..<h { for x in 0..<w where box(x, y) { inside += p[y * w + x] } }
            check("\(name) lies in its \([.bodySkin, .hair].contains(kind) ? "person" : "face")", inside / total > 0.95, "\(Int(inside / total * 100))% inside")
            // A half-size picture gives the same mask (scaled up, then compared where it's clearly in).
            if let half {
                let small = PhotoMasks.faceMask(kind, person: nil, in: half, context: context)
                let up = values(small.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / small.extent.width, y: CGFloat(h) / small.extent.height)))
                var both: Float = 0, either: Float = 0
                for i in 0..<(w * h) { let a = p[i] > 0.5, b = up[i] > 0.5; if a && b { both += 1 }; if a || b { either += 1 } }
                let overlap = either > 0 ? both / either : 1
                check("\(name) at half size agrees", overlap > 0.6, "overlap \(Int(overlap * 100))%")
            }
        }
        if let skin = planes[.faceSkin] {
            for kind in [MaskPart.Kind.eyes, .lips] {
                guard let part = planes[kind] else { continue }
                let total = part.reduce(0, +), shared = zip(part, skin).reduce(0) { $0 + min($1.0, $1.1) }
                check("face masks: \(kind.rawValue) stay out of face skin", total < 20 || shared / total < 0.15, "\(Int(shared / max(total, 1) * 100))% shared")
            }
        }
        // One person is part of everyone.
        if let all = planes[.face] {
            let one = values(PhotoMasks.faceMask(.face, person: 0, in: scan, context: context))
            let total = one.reduce(0, +), shared = zip(one, all).reduce(0) { $0 + min($1.0, $1.1) }
            check("face masks: person 1 is part of all people", total > 20 && shared / total > 0.98, "\(Int(shared / max(total, 1) * 100))%")
            let none = values(PhotoMasks.faceMask(.face, person: scan.faces.count, in: scan, context: context)).reduce(0, +)
            check("face masks: a person not there is empty", none < 1, "\(none)")
        }
    }

    /// For looking at: each part's mask (white = in) and the photo with the lip landmarks drawn (outer green, inner red),
    /// as PNGs in <photos>/../facemasks-debug, with each part's coverage and the teeth's numbers as notes.
    private static func faceDebug(_ name: String, image: CIImage, scan: PhotoMasks.FaceScan, into folder: URL, context: CIContext) {
        let stem = (name as NSString).deletingPathExtension, w = scan.width, h = scan.height
        func save(_ cg: CGImage, _ file: String) {
            guard let out = CGImageDestinationCreateWithURL(folder.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(out, cg, nil)
            CGImageDestinationFinalize(out)
        }
        for kind in [MaskPart.Kind.face, .faceSkin, .bodySkin, .eyes, .brows, .lips, .teeth, .hair] {
            let mask = PhotoMasks.faceMask(kind, person: nil, in: scan, context: context)
            var bytes = [UInt8](repeating: 0, count: w * h)
            context.render(mask, toBitmap: &bytes, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: nil)
            let coverage = Float(bytes.reduce(0) { $0 + Int($1) }) / 255 / Float(w * h)
            note("face debug \(name) \(kind.rawValue): coverage \(String(format: "%.4f", coverage))")
            if let provider = CGDataProvider(data: Data(bytes) as CFData),
               let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                save(cg, "\(stem)-\(kind.rawValue).png")
            }
        }
        for (k, face) in scan.faces.enumerated() {
            let t = PhotoMasks.teeth(face, in: scan).stats
            note("face debug \(name) person \(k + 1) teeth: inner-lip share \(String(format: "%.3f", t.openingShare))"
                 + (t.fromImage ? " (nearly closed: opening from the picture)" : "")
                 + ", lip ring lightness \(String(format: "%.3f", t.lipLuma)), saturation \(String(format: "%.3f", t.lipSat)), max lightness inside \(String(format: "%.3f", t.maxLuma))")
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let photo = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: w, height: h)),
              let canvas = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        canvas.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))
        canvas.setLineWidth(1.5)
        for face in scan.faces {
            for (points, colour) in [(face.outerLips, CGColor(red: 0, green: 1, blue: 0, alpha: 1)), (face.innerLips, CGColor(red: 1, green: 0, blue: 0, alpha: 1))]
            where points.count >= 2 {
                canvas.setStrokeColor(colour)
                canvas.beginPath(); canvas.addLines(between: points); canvas.closePath(); canvas.strokePath()
            }
        }
        if let drawn = canvas.makeImage() { save(drawn, "\(stem)-lips.png") }
    }
}
