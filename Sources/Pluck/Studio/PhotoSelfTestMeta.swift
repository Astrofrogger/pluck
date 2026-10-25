import ImageIO
import UniformTypeIdentifiers

/// A metadata template on import (Task 18): tokens, the sidecar and exports.
extension PhotoSelfTest {
    static func metadata() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-meta-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A grey JPEG taken in 2026 by a camera.
        let photo = folder.appendingPathComponent("DSC_0042.jpg")
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        if let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, context.makeImage()!, [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:17 14:03:00"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Nikon", kCGImagePropertyTIFFModel: "Nikon Z 6"],
            ] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }

        var template = PhotoMeta()
        template.creator = "Anna Berg"
        template.copyright = "© {year} Northwind"
        template.title = "{filename}"
        template.description = "{camera}, {date}"
        template.keywords = ["street", "{card}"]
        let filled = PhotoMetadataTemplate.expand(template, file: photo, card: "NIKON_Z6")
        check("template expands tokens", filled.copyright == "© 2026 Northwind" && filled.title == "DSC_0042"
              && filled.description == "Nikon Z 6, 2026-05-17" && filled.keywords == ["street", "NIKON_Z6"],
              "© 2026 Northwind, DSC_0042, Nikon Z 6, 2026-05-17; got \(String(describing: filled.copyright)), \(String(describing: filled.title)), \(String(describing: filled.description)), \(filled.keywords)")

        // Into the sidecar, read back by ImageIO as other apps would.
        var record = PhotoRecord()
        record.meta = filled
        try? PhotoXMP.write(photo.path, record: record)
        let sidecar = PhotoXMP.sidecars(for: photo.path)[0]
        let xmp = (try? Data(contentsOf: sidecar)).flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
        func value(_ path: String) -> String? { xmp.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, path as CFString) as String? } }
        check("xmp writes creator and keywords", value("dc:creator[0]") == "Anna Berg" && value("dc:subject[0]") == "street"
              && value("dc:rights[x-default]") == "© 2026 Northwind",
              "creator, keyword, rights; got \(String(describing: value("dc:creator[0]"))), \(String(describing: value("dc:subject[0]"))), \(String(describing: value("dc:rights[x-default]")))")

        // An export carries the copyright (unless no metadata goes along).
        var settings = PhotoExportSettings()
        settings.format = .jpeg
        let out = folder.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let made = try? await PhotoRender.export(photo.path, record: record, to: out, settings: settings)
        let properties = made.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        let iptc = properties?[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        check("export carries copyright", iptc?[kCGImagePropertyIPTCCopyrightNotice as String] as? String == "© 2026 Northwind",
              "the notice; got \(String(describing: iptc))")
        settings.metadata = .none
        settings.naming = .custom
        settings.name = "plain"
        let plain = try? await PhotoRender.export(photo.path, record: record, to: out, settings: settings)
        let bare = plain.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        check("no metadata means none", bare?[kCGImagePropertyIPTCDictionary as String] == nil, "no IPTC; got \(String(describing: bare?[kCGImagePropertyIPTCDictionary as String]))")

        // Old records have none.
        let old = try? JSONDecoder().decode(PhotoRecord.self, from: Data(#"{"rating":3}"#.utf8))
        check("old record has no metadata", old?.rating == 3 && old?.meta == nil)
    }
}
