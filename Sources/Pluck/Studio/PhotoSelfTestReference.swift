import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension PhotoSelfTest {
    /// Old edits stay as they were: process 1, 2 and 3 renders (as shot and edited) of two ARWs, a CR3 and a JPEG, against
    /// renders kept in `<photos>/../libraw-reference` (made once, before process 4 existed: `index.json` holds each one's
    /// SHA-256 of its sRGB pixels and means, the PNGs beside it). A render not there yet is made and kept.
    static func oldEditsUnchanged() async {
        let base = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let folder = base.appendingPathComponent("libraw-reference"), indexURL = folder.appendingPathComponent("index.json")
        let raws = base.appendingPathComponent("shootout/raws")
        let files = ["DSC01962.ARW", "DSC02868.ARW", "R6LO8181.CR3"].map { raws.appendingPathComponent($0) } + [URL(fileURLWithPath: photos).appendingPathComponent("one.jpg")]
        struct Entry: Codable { var sha256: String; var mean: [Double]; var width: Int; var height: Int }
        var index = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: indexURL))) ?? [:]
        var added = 0
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        func pixels(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            px.withUnsafeMutableBytes {
                let c = CGContext(data: $0.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return px
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            // (And a film edit: the film's light, which process 4 gives the profile's colour, as it was for 1–3.)
            for (process, edited, film) in (1...3).flatMap({ p in [(p, false, false), (p, true, false)] }) + (file == files[0] ? [(3, false, true)] : []) {
                do {
                    var record = PhotoRecord()
                    record.adjust.process = process
                    if film { record.filmOn = true; record.adjust.profile = .vivid }
                    if edited {
                        record.adjust.exposure = 0.4; record.adjust.contrast = 20; record.adjust.highlights = -60; record.adjust.shadows = 50
                        record.adjust.whites = 10; record.adjust.blacks = -10; record.adjust.temperature = 15; record.adjust.tint = -10
                        record.adjust.vibrance = 15; record.adjust.saturation = 10; record.adjust.clarity = 15; record.adjust.sharpen = 30
                    }
                    let name = "\(file.deletingPathExtension().lastPathComponent)-p\(process)-\(film ? "film-vivid" : edited ? "edited" : "shot")"
                    BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
                    guard let picture = try? await PhotoRender.develop(file.path, record: record, maxSize: 1200) else {
                        check("old edits unchanged \(name)", false, "not rendered"); continue
                    }
                    let px = pixels(picture)
                    let hash = SHA256.hash(data: px).map { String(format: "%02x", $0) }.joined()
                    let n = Double(px.count / 4)
                    let mean = (0..<3).map { c in stride(from: c, to: px.count, by: 4).reduce(0.0) { $0 + Double(px[$1]) } / n }
                    if let kept = index[name] {
                        var most = 0, differ = 0
                        if let src = CGImageSourceCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL, nil),
                           let old = CGImageSourceCreateImageAtIndex(src, 0, nil), old.width == picture.width, old.height == picture.height {
                            let was = pixels(old)
                            for i in px.indices where px[i] != was[i] { differ += 1; most = max(most, abs(Int(px[i]) - Int(was[i]))) }
                        }
                        check("old edits unchanged \(name)", kept.sha256 == hash && kept.width == picture.width && kept.height == picture.height,
                              "\(picture.width)×\(picture.height) against \(kept.width)×\(kept.height); \(differ) values differ, by at most \(most); means \(mean) against \(kept.mean)")
                    } else if let out = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(out, picture, nil)
                        if CGImageDestinationFinalize(out) {
                            index[name] = Entry(sha256: hash, mean: mean, width: picture.width, height: picture.height); added += 1
                            note("old edits unchanged \(name) made: \(picture.width)×\(picture.height), sha256 \(hash.prefix(16))…, means \(mean.map { String(format: "%.2f", $0) })")
                        }
                    }
                }
            }
        }
        BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
        if added > 0 {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(index).write(to: indexURL)
        }
        if index.isEmpty { skip("old edits unchanged", "no test files") }
    }
}
