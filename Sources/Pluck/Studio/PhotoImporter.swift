import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The import's logic, apart from its sheet: cameras told apart (make, model, serial), a clock offset
/// per camera, RAW+JPEG kept together as one item, and the copy read back and checked.
/// The originals on a card are never changed: dates are shifted only in the copies' sidecars.
enum PhotoImporter {
    struct Camera: Identifiable, Hashable {
        var key: String
        var label: String
        var photos: [URL]
        var id: String { key }
    }

    /// One photo to bring in: the RAW (or else the first file) and the files with the same name beside it.
    struct Item: Hashable {
        var primary: URL
        var companions: [URL] = []
        var members: [URL] { [primary] + companions }
    }

    /// An item with the date it counts as taken (camera clock + its camera's offset).
    struct Planned {
        var item: Item
        var date: Date
        var offset: TimeInterval
    }

    /// What a copy to a card's photos ended as: safe to format only when every photo was copied
    /// (to every copy) and read back identical.
    struct Report {
        var total = 0
        var copied = 0
        var copies = 1
        var failed: [String] = []
        var safe: Bool { total > 0 && copied == total && failed.isEmpty }

        /// One item's result in; its copy's path, or nil for a failure (named in `failed`).
        mutating func add(_ result: Result<String, Error>, _ name: String) -> String? {
            switch result {
            case .success(let path): copied += 1; return path
            case .failure: failed.append(name); return nil
            }
        }
    }

    /// Tests only: runs on each fresh copy before it is read back (to corrupt it).
    nonisolated(unsafe) static var afterCopy: ((URL) -> Void)?

    // MARK: - What a photo says

    nonisolated static func meta(_ url: URL) -> (date: Date?, camera: (key: String, label: String)?) {
        var date = sidecarDate(url)
        var camera: (key: String, label: String)?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            if date == nil, let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String { date = parse(text) }
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let make = (tiff?[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let model = (tiff?[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let serial = (exif?[kCGImagePropertyExifBodySerialNumber] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !make.isEmpty || !model.isEmpty || !serial.isEmpty {
                let label = model.lowercased().hasPrefix(make.lowercased()) ? model : [make, model].filter { !$0.isEmpty }.joined(separator: " ")
                camera = ("\(make)|\(model)|\(serial)".lowercased(), label.isEmpty ? serial : label)
            }
        }
        return (date, camera)
    }

    /// When it was taken: a sidecar's date (one this import shifted), the camera's own date, or the file's date.
    nonisolated static func captureDate(_ photo: URL) -> Date {
        meta(photo).date ?? (try? photo.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
    }

    nonisolated static func sidecarDate(_ url: URL) -> Date? {
        for sidecar in PhotoXMP.sidecars(for: url.path) {
            guard let data = try? Data(contentsOf: sidecar), let xmp = CGImageMetadataCreateFromXMPData(data as CFData) else { continue }
            for path in ["exif:DateTimeOriginal", "xmp:CreateDate"] {
                if let text = CGImageMetadataCopyStringValueWithPath(xmp, nil, path as CFString) as String?, let date = parse(text) { return date }
            }
        }
        return nil
    }

    nonisolated static func parse(_ text: String) -> Date? {
        let head = String(text.prefix(19))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            format.dateFormat = pattern
            if let date = format.date(from: head) { return date }
        }
        return nil
    }

    nonisolated static func stamp(_ date: Date, _ pattern: String) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = pattern
        return format.string(from: date)
    }

    // MARK: - Cameras

    /// The cameras the photos came from (told apart by make, model and serial), by name.
    nonisolated static func cameras(in photos: [URL]) -> [Camera] {
        var found: [String: Camera] = [:]
        for photo in photos {
            guard let camera = meta(photo).camera else { continue }
            found[camera.key, default: Camera(key: camera.key, label: camera.label, photos: [])].photos.append(photo)
        }
        var list = found.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending || ($0.label == $1.label && $0.key < $1.key) }
        // (Two bodies of one model: told apart by the end of the serial.)
        for i in list.indices where list.filter({ $0.label == list[i].label }).count > 1 {
            let serial = list[i].key.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if !serial.isEmpty { list[i].label += " · " + serial.suffix(4) }
        }
        return list
    }

    // MARK: - RAW + JPEG as one

    nonisolated static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
    }

    /// Photos with the same name in one folder are one item (the RAW is the photo, the JPEG kept beside it).
    nonisolated static func items(_ photos: [URL]) -> [Item] {
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        for photo in photos {
            let key = photo.deletingLastPathComponent().path + "/" + photo.deletingPathExtension().lastPathComponent.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(photo)
        }
        return order.map { key in
            let group = groups[key] ?? []
            let primary = group.first(where: isRaw) ?? group[0]
            return Item(primary: primary, companions: group.filter { $0 != primary })
        }
    }

    // MARK: - Order and clock offsets

    /// The items in the order they were taken, each camera's clock shifted by its offset.
    nonisolated static func plan(_ items: [Item], offsets: [String: TimeInterval]) -> [Planned] {
        let planned: [Planned] = items.map { item in
            let metas = item.members.map(meta)
            let camera = metas.compactMap(\.camera).first
            let taken = metas.compactMap(\.date).first
                ?? (try? item.primary.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let offset = camera.flatMap { offsets[$0.key] } ?? 0
            return Planned(item: item, date: taken.addingTimeInterval(offset), offset: offset)
        }
        return planned.enumerated().sorted { $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset }.map(\.element)
    }

    // MARK: - Copying

    /// One item copied (its companions and sidecars too) to the folder and the backup; the copy's path.
    /// The same photo already there (also as name-2, -3… from an earlier import) isn't copied again;
    /// another photo with this name (a second card) is kept as name-2, -3….
    nonisolated static func copy(_ planned: Planned, to folder: URL, backup: URL?, byDate: Bool, rename: Bool) -> Result<String, Error> {
        let item = planned.item
        let subfolder = byDate ? stamp(planned.date, "yyyy/yyyy-MM-dd") : ""
        let original = item.primary.deletingPathExtension().lastPathComponent
        let stem = rename ? stamp(planned.date, "yyyyMMdd-HHmmss") + "-" + original : original
        var main = ""
        for (i, root) in ([folder] + (backup.map { [$0] } ?? [])).enumerated() {
            let place = subfolder.isEmpty ? root : root.appendingPathComponent(subfolder, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                func target(_ member: URL, _ n: Int) -> URL {
                    let name = n == 1 ? stem : stem + "-\(n)"
                    return place.appendingPathComponent(member.pathExtension.isEmpty ? name : name + "." + member.pathExtension)
                }
                // One number for the whole item, so a RAW and its JPEG stay a pair.
                var n = 1
                while item.members.contains(where: { FileManager.default.fileExists(atPath: target($0, n).path) && !sameFile($0, target($0, n)) }) { n += 1 }
                let finalStem = n == 1 ? stem : stem + "-\(n)"
                for member in item.members {
                    let spot = target(member, n)
                    if !FileManager.default.fileExists(atPath: spot.path) {
                        try FileManager.default.copyItem(at: member, to: spot)
                        try checked(member, spot)
                    }
                    if member == item.primary && i == 0 { main = spot.path }
                    // Its sidecar too (named after the copy).
                    for sidecar in PhotoXMP.sidecars(for: member.path) where FileManager.default.fileExists(atPath: sidecar.path) {
                        let ofPhoto = sidecar.lastPathComponent.lowercased() == member.deletingPathExtension().lastPathComponent.lowercased() + ".xmp"
                        let name = ofPhoto ? finalStem + ".xmp" : spot.lastPathComponent + ".xmp"
                        let to = place.appendingPathComponent(name)
                        if !FileManager.default.fileExists(atPath: to.path) { try? FileManager.default.copyItem(at: sidecar, to: to) }
                    }
                }
                // A camera's clock shifted: the date goes into the copy's sidecar, not the photo.
                if planned.offset != 0 {
                    try PhotoXMP.writeDate(target(item.primary, n).path, taken: stamp(planned.date, "yyyy-MM-dd'T'HH:mm:ss"), offset: planned.offset)
                }
            } catch {
                return .failure(error)
            }
        }
        return .success(main)
    }

    /// The copy read back and compared with the card's (as Offload does): a bad one is removed
    /// and the import stops, so nothing is filed that isn't the photo.
    nonisolated private static func checked(_ photo: URL, _ copy: URL) throws {
        func digest(_ url: URL) throws -> SHA256.Digest {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize()
        }
        afterCopy?(copy)
        guard try digest(photo) == digest(copy) else {
            try? FileManager.default.removeItem(at: copy)
            throw NSError(domain: "Pluck", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "The copy of “\(photo.lastPathComponent)” didn’t match the original. Check the card and the drive, then import again.")])
        }
    }

    nonisolated private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let one = try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let two = try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        // (Same size alone isn't enough: two cards' IMG_0001.JPG can be.)
        return one == two && FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }
}
