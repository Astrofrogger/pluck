import Foundation
import ImageIO

/// Ratings, labels and flags shared with other photo apps through XMP: read from a sidecar
/// (`IMG_0001.xmp` or `IMG_0001.CR3.xmp`) or the file itself, and, when asked, written to
/// `IMG_0001.xmp`. Writing merges: whatever other apps keep there (Lightroom's edits too) stays.
/// Pluck's own edit goes along in its own namespace, so it survives losing Pluck's catalogue.
/// Through macOS's own XMP support (ImageIO): no third-party code.
enum PhotoXMP {
    static let namespace = "https://ns.pluck.local/photo/1.0/" as CFString
    static let prefix = "pluck" as CFString

    /// What another app (or Pluck, earlier) wrote about a photo.
    struct Found {
        var rating: Int?
        var label: String?
        var rejected = false
        /// Pluck's own edit, when it wrote one.
        var record: PhotoRecord?
    }

    /// The sidecars a photo may have, the one Pluck writes first.
    static func sidecars(for path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        return [url.deletingPathExtension().appendingPathExtension("xmp"), url.appendingPathExtension("xmp")]
    }

    /// What the sidecar (or else the photo itself) says; nil when nothing.
    static func read(_ path: String) -> Found? {
        for sidecar in sidecars(for: path) {
            if let data = try? Data(contentsOf: sidecar), let metadata = CGImageMetadataCreateFromXMPData(data as CFData),
               let found = found(in: metadata) {
                return found
            }
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        return found(in: metadata)
    }

    private static func found(in metadata: CGImageMetadata) -> Found? {
        var found = Found()
        if let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?, let value = Int(text) {
            if value < 0 { found.rejected = true } else { found.rating = min(value, 5) }
        }
        if let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Label" as CFString) as String? {
            found.label = label(fromXMP: text)
        }
        if let recipe = recipeTag(in: metadata), let data = Data(base64Encoded: recipe),
           let record = try? JSONDecoder().decode(PhotoRecord.self, from: data) {
            found.record = record
        }
        return found.rating == nil && found.label == nil && !found.rejected && found.record == nil ? nil : found
    }

    /// Pluck's edit, found by its namespace (whatever prefix the file gives it).
    private static func recipeTag(in metadata: CGImageMetadata) -> String? {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return nil }
        for tag in tags where (CGImageMetadataTagCopyNamespace(tag) as String?) == namespace as String
            && (CGImageMetadataTagCopyName(tag) as String?) == "Recipe" {
            return CGImageMetadataTagCopyValue(tag) as? String
        }
        return nil
    }

    /// Writes the rating, label and flag (reject is a rating of -1, as Lightroom does) and Pluck's
    /// edit into the photo's sidecar, keeping everything else in it. Atomic.
    static func write(_ path: String, record: PhotoRecord) throws {
        let sidecar = sidecars(for: path)[0]
        let metadata: CGMutableImageMetadata
        if let data = try? Data(contentsOf: sidecar), let existing = CGImageMetadataCreateFromXMPData(data as CFData),
           let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil)
        let rating = record.flag == .reject ? -1 : record.rating
        CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "\(rating)" as CFString)
        if let label = record.label {
            CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Label" as CFString, xmpLabel(label) as CFString)
        } else {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Label" as CFString)
        }
        if record.isEdited || record.flag == .pick, let data = try? JSONEncoder().encode(record) {
            CGImageMetadataSetValueWithPath(metadata, nil, "pluck:Recipe" as CFString, data.base64EncodedString() as CFString)
        } else {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "pluck:Recipe" as CFString)
        }
        guard let xmp = CGImageMetadataCreateXMPData(metadata, nil) as Data? else {
            throw NSError(domain: "Pluck", code: 20, userInfo: [NSLocalizedDescriptionKey: "The XMP couldn’t be made."])
        }
        try xmp.write(to: sidecar, options: .atomic)
    }

    /// Lightroom's label names (it has no orange).
    private static func xmpLabel(_ label: String) -> String {
        ["red": "Red", "orange": "Orange", "yellow": "Yellow", "green": "Green", "blue": "Blue", "purple": "Purple"][label] ?? label.capitalized
    }

    private static func label(fromXMP text: String) -> String? {
        let name = text.lowercased()
        return ["red", "orange", "yellow", "green", "blue", "purple"].contains(name) ? name : nil
    }
}
