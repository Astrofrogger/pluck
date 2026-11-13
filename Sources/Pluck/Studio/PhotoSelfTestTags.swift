import CoreGraphics
import Foundation

/// Automatic tags and the Browse search (-PluckScreenshotOnly tags): an old catalogue reads and writes again
/// byte for byte, tags are saved and read back apart from the records, the search needs every word (prefix,
/// plural, case and accents), and Vision's tagging runs on a photo (from -PluckScreenshotPhotos, else drawn).
extension PhotoSelfTest {
    static func tags() async {
        // The catalogue as it was before tags.
        struct OldSaved: Codable {
            var records: [String: PhotoRecord]
            var albums: [PhotoAlbum]
            var folders: [AlbumFolder]?
            var presets: [PhotoPreset]?
        }
        var record = PhotoRecord()
        record.rating = 3
        record.adjust.exposure = 0.5
        var meta = PhotoMeta()
        meta.keywords = ["Holiday"]
        record.meta = meta
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let old = try? encoder.encode(OldSaved(records: ["/photos/a.jpg": record, "/photos/b.jpg": PhotoRecord()],
                                               albums: [PhotoAlbum(name: "Trip", paths: ["/photos/a.jpg"])], folders: [], presets: nil))
        let again = old.flatMap(PhotoCatalog.reencoded)
        check("tags: an old catalogue is written again byte for byte", old != nil && again == old,
              "\(old?.count ?? 0) vs \(again?.count ?? 0) bytes")
        check("tags: no tags key without tags", again.map { !String(decoding: $0, as: UTF8.self).contains("\"tags\"") } ?? false)

        // Search, on made-up photos.
        let a = PhotoSearch.words("IMG_0001.jpg dog beach sand Café puppy")
        let b = PhotoSearch.words("IMG_0002.jpg dog grass")
        func finds(_ query: String, _ photo: [String]) -> Bool { PhotoSearch.matches(PhotoSearch.words(query), photo) }
        check("tags: every word must be found", finds("dog beach", a) && !finds("dog beach", b))
        check("tags: words match their start", finds("do bea", a) && !finds("each", a))
        check("tags: plurals find the singular", finds("dogs beaches", a) && finds("puppies", a) && !finds("cats", a))
        check("tags: case and accents don't matter", finds("CAFE", a) && finds("café", PhotoSearch.words("cafe")) && finds("DÖG", a))
        check("tags: the file name is searched", finds("img_0002", b) && !finds("img_0002", a))
        check("tags: an empty search finds nothing to match", PhotoSearch.words("  ,  ").isEmpty)

        // Stored apart from the records, and read back (only with the tests' own catalogue).
        guard UserDefaults.standard.string(forKey: "PluckScreenshotCatalog") != nil else {
            skip("tags: saved and read back", "no -PluckScreenshotCatalog")
            return
        }
        let catalog = PhotoCatalog.shared
        let fake = "/photos/tagged-\(UUID().uuidString).jpg"
        let given = PhotoTags(labels: ["dog", "beach"], faces: 2)
        catalog.setTags(given, for: fake)
        catalog.saveNow()
        check("tags: saved and read back", PhotoCatalog.readTags()?[fake] == given, "\(String(describing: PhotoCatalog.readTags()?[fake]))")
        check("tags: not part of the record", PhotoCatalog.readFile()?[fake] == nil && catalog.record(fake) == PhotoRecord())
        check("tags: a copy has its original's", catalog.tags(of: fake + PhotoCatalog.copyMark + "2") == given)
        let searched = PhotoSearch.words(of: fake)
        check("tags: search sees the tags and faces", PhotoSearch.matches(PhotoSearch.words("dogs beach face"), searched), searched.joined(separator: " "))

        // Vision on a real photo, else a drawn one.
        let file = (try? FileManager.default.contentsOfDirectory(atPath: photos))?.sorted()
            .map { (photos as NSString).appendingPathComponent($0) }.first { PhotoCatalog.isPhoto(URL(fileURLWithPath: $0)) }
        var made: PhotoTags?
        let start = Date.now
        if let file {
            made = await Task.detached { PhotoTags.make(file) }.value
        } else if let image = drawnPicture() {
            made = await Task.detached { PhotoTags.make(image) }.value
        }
        note("tags: \(file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "drawn picture") in \(Int(Date.now.timeIntervalSince(start) * 1000)) ms (first, with Vision's start-up): \(made?.labels.joined(separator: ", ") ?? "-"), faces \(made?.faces ?? -1)")
        if let made {
            check("tags: Vision's tags are few and plain", made.labels.count <= 12 && !made.labels.contains { $0.contains("_") || PhotoTags.generic.contains($0) }
                  && made.version == PhotoTags.currentVersion, made.labels.joined(separator: ", "))
        } else {
            check("tags: Vision's tagging runs", false, "no tags from \(file ?? "the drawn picture")")
        }
        if let file {
            let again = Date.now
            for _ in 0..<5 { _ = await Task.detached { PhotoTags.make(file) }.value }
            note("tags: \(Int(Date.now.timeIntervalSince(again) * 200)) ms a photo, warm")
            // Older tags are made again in the background.
            catalog.setTags(PhotoTags(version: 0, labels: []), for: file)
            PhotoTagger.shared.enqueue([file], first: true)
            for _ in 0..<100 where (catalog.tags[file]?.version ?? 0) < PhotoTags.currentVersion { try? await Task.sleep(for: .milliseconds(100)) }
            check("tags: older tags are made again", catalog.tags[file]?.version == PhotoTags.currentVersion)
        }
    }

    /// A blue sky over sand, to tag when there's no photo.
    private static func drawnPicture() -> CGImage? {
        guard let context = CGContext(data: nil, width: 512, height: 384, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.75, blue: 0.55, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 160))
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.6, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 160, width: 512, height: 224))
        return context.makeImage()
    }
}
