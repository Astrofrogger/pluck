import Foundation
import ImageIO
import Vision

/// What Vision on this Mac sees in a photo (its own words, in English) and how many faces: kept in the
/// catalogue apart from the photo's own keywords, never part of its edit.
struct PhotoTags: Codable, Hashable {
    /// Raised when the tagging gets better: tags made by an older one are made again.
    static let currentVersion = 1
    var version = currentVersion
    /// Strongest first.
    var labels: [String]
    var faces: Int?

    /// What search looks through: the labels, and "face" when there are faces.
    var words: [String] { labels + ((faces ?? 0) > 0 ? ["face"] : []) }

    /// Too broad to be worth a tag.
    static let generic: Set<String> = ["structure", "material", "textile", "liquid", "wood_processed"]

    /// From a small preview (a camera's own when it has one): Vision's classes at 0.3 and up, at most 12.
    nonisolated static func make(_ path: String) -> PhotoTags? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        func preview(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                            kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // A JPEG's tiny embedded thumbnail is too small to see faces in: made from the picture then.
        guard var image = preview(always: false) else { return nil }
        if max(image.width, image.height) < 300, let bigger = preview(always: true) { image = bigger }
        return make(image)
    }

    nonisolated static func make(_ image: CGImage) -> PhotoTags {
        let classify = VNClassifyImageRequest(), faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([classify, faces])
        let labels = (classify.results ?? []).filter { $0.confidence >= 0.3 && !generic.contains($0.identifier) }
            .sorted { $0.confidence > $1.confidence }.prefix(12).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return PhotoTags(labels: Array(labels), faces: (faces.results ?? []).filter { $0.boundingBox.width > 0.04 }.count)
    }
}

/// Tags the photos without tags (or with older ones), one at a time, at background priority, never while
/// a photo is being edited. Each is saved as it's done, so a quit carries on where it stopped next time.
@MainActor
final class PhotoTagger {
    static let shared = PhotoTagger()
    private var waiting: [String] = []
    private var task: Task<Void, Never>?

    private func needs(_ file: String) -> Bool { (PhotoCatalog.shared.tags[file]?.version ?? 0) < PhotoTags.currentVersion }

    /// `first`: ahead of the others (new imports).
    func enqueue(_ keys: [String], first: Bool = false) {
        let new = PhotoCatalog.files(of: keys).filter(needs)
        guard !new.isEmpty else { return }
        let moved = Set(new)
        waiting.removeAll { moved.contains($0) }
        waiting = first ? new + waiting : waiting + new
        run()
    }

    func cancel() {
        waiting = []
        task?.cancel()
    }

    private func run() {
        guard task == nil, !waiting.isEmpty else { return }
        task = Task {
            // (Not while the page is showing its first photo: tagging waits a few seconds after it starts.)
            try? await Task.sleep(for: .seconds(4))
            while !waiting.isEmpty, !Task.isCancelled {
                // A slider being dragged (or any edit just now): wait until it's put down.
                if Date.now.timeIntervalSince(PhotoCatalog.shared.lastEdit) < 2 {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let file = waiting.removeFirst()
                guard needs(file) else { continue }
                // A file that can't be read (a drive asleep) is tried again next launch.
                if let tags = await Task.detached(priority: .background, operation: { PhotoTags.make(file) }).value {
                    PhotoCatalog.shared.setTags(tags, for: file)
                }
            }
            task = nil
            // Photos queued after a cancel, while the last one was still being looked at.
            if !waiting.isEmpty { run() }
        }
    }
}

/// The Browse search: every word typed must start a word of the photo's name, keywords or tags (or the
/// text in it), whatever the case or accents. "dog beach" finds photos of dogs on a beach; "dogs" finds "dog".
enum PhotoSearch {
    nonisolated static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The word and its singular ("beaches" → "beach", "puppies" → "puppy").
    nonisolated static func forms(_ word: String) -> [String] {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else { return [word] }
        var forms = [word, String(word.dropLast())]
        if word.hasSuffix("ies") { forms.append(word.dropLast(3) + "y") }
        if word.hasSuffix("es") { forms.append(String(word.dropLast(2))) }
        return forms
    }

    /// `query` and `photo` as `words` gives them.
    nonisolated static func matches(_ query: [String], _ photo: [String]) -> Bool {
        query.allSatisfy { word in forms(word).contains { form in photo.contains { $0.hasPrefix(form) } } }
    }

    /// A photo's words: its name, keywords, tags and the text in it.
    @MainActor static func words(of key: String) -> [String] {
        let catalog = PhotoCatalog.shared
        let file = PhotoCatalog.file(of: key)
        let parts = [PhotoCatalog.displayName(key)] + (catalog.record(key).meta?.keywords ?? []) + (catalog.tags[file]?.words ?? [])
            + [PhotoIndex.shared.entries[file]?.text ?? ""]
        return words(parts.joined(separator: " "))
    }
}
