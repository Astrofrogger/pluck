import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Renders a real photo kept outside the repo (mode "phototest", -PluckScreenshotOnly real): `<photos>/../greencast/
/// renders.json` lists {"name", "file", "record" (a PhotoRecord), "clean" (an EXR standing in for the denoiser)};
/// each comes out as `<name>.jpg` beside it. Without that list, nothing runs.
extension PhotoSelfTest {
    static func realFile() async {
        let folder = URL(fileURLWithPath: photos).deletingLastPathComponent().appendingPathComponent("greencast")
        struct Job: Decodable { var name: String; var file: String; var record: PhotoRecord; var clean: String?; var size: Int? }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("renders.json")),
              let jobs = try? JSONDecoder().decode([Job].self, from: data) else { skip("real file renders", "no renders.json"); return }
        let before = PhotoRender.denoiseEngineForTests
        defer { PhotoRender.denoiseEngineForTests = before }
        for job in jobs {
            let path = folder.appendingPathComponent(job.file).path
            guard FileManager.default.fileExists(atPath: path) else { skip("real file \(job.name)", "no \(job.file)"); continue }
            if let clean = job.clean {
                PhotoRender.denoiseEngineForTests = { _, output, _ in try FileManager.default.copyItem(at: URL(fileURLWithPath: clean), to: output) }
                if let made = PhotoRender.denoised(path, record: job.record) { try? FileManager.default.removeItem(at: made) }
                try? await PhotoRender.denoise(path, record: job.record)
            }
            BaseCache.shared.removeAll(); GuideCache.shared.removeAll()
            guard let image = PhotoRender.image(path, record: job.record, maxSize: job.size ?? 1500),
                  let picture = PhotoRender.picture(image, maxSize: job.size ?? 1500),
                  let out = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(job.name).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { check("real file \(job.name)", false, "not rendered"); continue }
            CGImageDestinationAddImage(out, picture, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            check("real file \(job.name)", CGImageDestinationFinalize(out))
        }
    }
}
