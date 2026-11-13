import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension PhotoSelfTest {
    /// Every profile on the RAWs listed in <photos>/../profiles/jobs.txt, as JPEGs in profiles/dump (name-process-profile.jpg),
    /// to compare them side by side. -PluckScreenshotProcess <n…>: the processes to render (default: the current one).
    static func profileDump() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("profiles")
        guard let list = try? String(contentsOf: folder.appendingPathComponent("jobs.txt"), encoding: .utf8) else { skip("profile dump", "no jobs.txt"); return }
        let out = folder.appendingPathComponent("dump")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let processes = (UserDefaults.standard.string(forKey: "PluckScreenshotProcess") ?? "\(PhotoAdjustments.currentProcess)")
            .split(separator: ",").compactMap { Int($0) }
        let profiles: [PhotoEngine.Profile] = [.standard, .neutral, .vivid, .landscape, .portrait, .mist, .dusk, .monochrome]
        for path in list.split(separator: "\n").map(String.init) where !path.isEmpty {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            for process in processes {
                for profile in profiles {
                    var record = PhotoRecord()
                    record.adjust.process = process
                    record.adjust.profile = profile
                    guard let decoded = PhotoRender.decoded(path, maxSize: 1400, record: record) else { check("profile dump \(name)", false, "not decoded"); continue }
                    let image = PhotoRender.output(PhotoRender.adjusted(decoded, record.adjust, path: path), record.adjust, p3: false)
                    let e = image.extent.integral
                    let placed = image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                    guard let cg = PhotoEngine.context.createCGImage(placed, from: placed.extent, format: .RGBA8, colorSpace: srgb),
                          let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("\(name)-p\(process)-\(profile.rawValue).jpg") as CFURL,
                                                                     UTType.jpeg.identifier as CFString, 1, nil) else { continue }
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                    check("profile dump \(name) p\(process) \(profile.rawValue)", CGImageDestinationFinalize(dest), "write")
                }
            }
        }
    }
}
