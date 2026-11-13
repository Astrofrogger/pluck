import CoreImage
import Foundation
import ImageIO

/// Merges through Pluck (-PluckScreenshotOnly merge): three copies of one test RAW merged as HDR and as a focus stack write a
/// DNG that Pluck knows as a merge and reads back as the source (brightness and colour within a few percent, the camera's
/// make kept); one photo alone isn't merged.
extension PhotoSelfTest {
    static func mergeTest() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent()
        let raw = folder.appendingPathComponent("raws/DSC02845.ARW")
        guard FileManager.default.fileExists(atPath: raw.path) else { skip("merge", "no RAW"); return }
        let work = folder.appendingPathComponent("merge-test", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let files = (1...3).map { work.appendingPathComponent("frame\($0).ARW") }
        for f in files { try? FileManager.default.copyItem(at: raw, to: f) }
        let context = PhotoEngine.context
        func stats(_ path: String) -> SIMD3<Float>? {
            guard let image = PhotoRender.decoded(path, maxSize: 1200, record: PhotoRecord()) else { return nil }
            let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var p = [Float](repeating: 0, count: 4)
            context.render(avg, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            return SIMD3(p[0], p[1], p[2])
        }
        guard let source = stats(files[0].path) else { check("merge: source decodes", false); return }
        for kind in [PhotoMerger.Kind.hdr, .focus] {
            let start = Date()
            do {
                let url = try PhotoMerger.make(kind, files: files.map(\.path))
                let seconds = Date().timeIntervalSince(start)
                check("merge \(kind.rawValue): a DNG beside the photos", url.pathExtension == "dng" && url.deletingLastPathComponent() == work, url.path)
                check("merge \(kind.rawValue): known as a merge", PhotoDNG.isMerge(url))
                guard let merged = stats(url.path) else { check("merge \(kind.rawValue): reads back", false); continue }
                let ratio = merged / source
                check("merge \(kind.rawValue): reads back as the source", ratio.min() > 0.93 && ratio.max() < 1.07, "source \(source), merged \(merged) in \(String(format: "%.1f", seconds)) s")
                let make = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
                    .flatMap { $0[kCGImagePropertyTIFFDictionary as String] as? [String: Any] }?[kCGImagePropertyTIFFMake as String] as? String
                check("merge \(kind.rawValue): the camera's make kept", make?.lowercased().contains("sony") == true, make ?? "none")
            } catch {
                check("merge \(kind.rawValue)", false, error.localizedDescription)
            }
        }
        do { _ = try PhotoMerger.make(.hdr, files: [files[0].path]); check("merge: one photo isn't merged", false) } catch {
            check("merge: one photo isn't merged", true)
        }
    }
}
