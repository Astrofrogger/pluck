import Foundation
import CoreGraphics
import ImageIO
import SQLite3

/// Reads a Lightroom catalog without touching it: opened read-only and immutable (no lock, no -shm),
/// and the previews database is read from a copy in Caches. Nothing is ever written next to the catalog.
struct LightroomCatalog {
    struct Collection: Identifiable, Hashable {
        let id: Int
        let name: String
        let photos: Int
        let keepers: Int
    }

    struct Photo: Hashable {
        let id: Int
        let captureTime: Date?
        let rating: Int
        /// Lightroom's orientation code: AB upright, DA turned 90° counter-clockwise, BC 90° clockwise, CD 180°.
        let orientation: String?
        /// Lightroom's develop settings text, as stored.
        let develop: String?
        let original: URL?
        /// Exposure time in seconds, ISO and focal length in mm, when the catalog has them.
        var shutter: Double? = nil
        var iso: Double? = nil
        var focalLength: Double? = nil
    }

    let url: URL

    /// Opens the catalog to check it can be read; throws if it can't.
    init(url: URL) throws {
        self.url = url
        guard let db = Self.open(url) else { throw CocoaError(.fileReadCorruptFile) }
        sqlite3_close(db)
    }

    /// The catalogs in ~/Pictures/Lightroom.
    static func defaultCatalogs() -> [URL] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Lightroom")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".lrcat") }.sorted().map { folder.appendingPathComponent($0) }
    }

    /// User collections that have at least one kept (rated 1 or more) photo.
    func collections() -> [Collection] {
        let sql = """
            SELECT c.id_local, c.name, COUNT(i.id_local), SUM(CASE WHEN i.rating >= 1 THEN 1 ELSE 0 END)
            FROM AgLibraryCollection c
            JOIN AgLibraryCollectionImage ci ON ci.collection = c.id_local
            JOIN Adobe_images i ON i.id_local = ci.image
            WHERE c.creationId = 'com.adobe.ag.library.collection'
            GROUP BY c.id_local ORDER BY c.name
            """
        return Self.query(url, sql) { s in
            Collection(id: Int(sqlite3_column_int64(s, 0)), name: Self.text(s, 1) ?? "",
                       photos: Int(sqlite3_column_int64(s, 2)), keepers: Int(sqlite3_column_int64(s, 3)))
        }.filter { $0.keepers >= 1 }
    }

    /// The photos of a collection.
    func photos(in collection: Int) -> [Photo] {
        let sql = """
            SELECT i.id_local, i.captureTime, i.rating, i.orientation, d.text,
                   rf.absolutePath, fo.pathFromRoot, f.baseName, f.extension,
                   e.shutterSpeed, e.isoSpeedRating, e.focalLength
            FROM AgLibraryCollectionImage ci
            JOIN Adobe_images i ON i.id_local = ci.image
            LEFT JOIN Adobe_imageDevelopSettings d ON d.image = i.id_local
            LEFT JOIN AgLibraryFile f ON f.id_local = i.rootFile
            LEFT JOIN AgLibraryFolder fo ON fo.id_local = f.folder
            LEFT JOIN AgLibraryRootFolder rf ON rf.id_local = fo.rootFolder
            LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local
            WHERE ci.collection = ? ORDER BY i.captureTime, i.id_local
            """
        return Self.query(url, sql, bind: { sqlite3_bind_int64($0, 1, Int64(collection)) }) { s in
            var original: URL?
            if let root = Self.text(s, 5), let base = Self.text(s, 7) {
                let ext = Self.text(s, 8)
                original = URL(fileURLWithPath: root + (Self.text(s, 6) ?? "") + base + (ext.map { "." + $0 } ?? ""))
            }
            func number(_ column: Int32) -> Double? { sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_double(s, column) }
            return Photo(id: Int(sqlite3_column_int64(s, 0)), captureTime: Self.text(s, 1).flatMap(Self.date),
                         rating: Int(sqlite3_column_int64(s, 2)), orientation: Self.text(s, 3), develop: Self.text(s, 4), original: original,
                         // The catalog keeps the shutter as an APEX value: seconds = 2^-apex.
                         shutter: number(9).map { pow(2, -$0) }, iso: number(10), focalLength: number(11))
        }
    }

    /// The smallest preview at least `longSide` px on its long side (the largest if none is), turned upright.
    func preview(of photo: Photo, longSide: Int) -> CGImage? {
        guard let previews = previewsFolder, let db = Self.openPreviews(previews, catalog: url) else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT uuid, digest FROM ImageCacheEntry WHERE imageId = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(photo.id))
        guard sqlite3_step(stmt) == SQLITE_ROW, let uuid = Self.text(stmt, 0), let digest = Self.text(stmt, 1), uuid.count >= 4 else { return nil }

        // The files are <uuid>-<digest>_<long side>: find which sizes exist.
        let folder = previews.appendingPathComponent(String(uuid.prefix(1))).appendingPathComponent(String(uuid.prefix(4)))
        let prefix = "\(uuid)-\(digest)_"
        let sizes = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }.sorted()
        guard let size = sizes.first(where: { $0 >= longSide }) ?? sizes.last else { return nil }
        let file = folder.appendingPathComponent(prefix + String(size))
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Self.upright(image, orientation: photo.orientation)
    }

    // MARK: Files

    /// `<name> Previews.lrdata`, next to the catalog.
    private var previewsFolder: URL? {
        let name = url.deletingPathExtension().lastPathComponent + " Previews.lrdata"
        let folder = url.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// This catalog's folder in Caches, with a stable name per catalog path (hashValue changes every launch).
    static func cacheFolder(for catalog: URL) -> URL {
        let key = String(catalog.path.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Lightroom/\(key)")
    }

    private static let copying = NSLock()

    /// Opens a copy of previews.db kept in Caches, refreshed when the original changes.
    private static func openPreviews(_ folder: URL, catalog: URL) -> OpaquePointer? {
        let fm = FileManager.default
        let source = folder.appendingPathComponent("previews.db")
        guard fm.fileExists(atPath: source.path) else { return nil }
        let caches = cacheFolder(for: catalog)
        try? fm.createDirectory(at: caches, withIntermediateDirectories: true)
        let copy = caches.appendingPathComponent("previews.db")
        func modified(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        // Training reads previews several at a time, while Lightroom may be writing: one copies at a time, each
        // file copied aside and then moved into place, so no reader ever opens a half-copied database.
        copying.withLock {
            if let a = modified(source), let b = modified(copy), a <= b { return } // the copy is current
            // Any journal travels with the database, so a copy taken mid-write is still readable.
            for suffix in ["-wal", "-shm", ""] {
                let from = URL(fileURLWithPath: source.path + suffix), to = URL(fileURLWithPath: copy.path + suffix)
                let aside = URL(fileURLWithPath: to.path + ".copying")
                try? fm.removeItem(at: aside)
                if fm.fileExists(atPath: from.path), (try? fm.copyItem(at: from, to: aside)) != nil {
                    if rename(aside.path, to.path) != 0 { try? fm.removeItem(at: aside) }
                } else {
                    try? fm.removeItem(at: to)
                }
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        return db
    }

    // MARK: SQLite

    /// Read-only and immutable: no lock, and no -shm or -wal is ever created.
    private static func open(_ catalog: URL) -> OpaquePointer? {
        var escaped = ""
        for byte in catalog.path.utf8 {
            // The URI needs these escaped.
            if byte == UInt8(ascii: "%") || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") { escaped += String(format: "%%%02X", byte) }
            else { escaped += String(decoding: [byte], as: UTF8.self) }
        }
        var db: OpaquePointer?
        let uri = "file:\(escaped)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        return db
    }

    private static func query<T>(_ catalog: URL, _ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> T) -> [T] {
        guard let db = open(catalog) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { rows.append(row(stmt)) }
        return rows
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(stmt, column).map { String(cString: $0) }
    }

    /// Lightroom writes times like 2024-05-01T12:30:00.5, without a zone.
    private static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let base = formatter.date(from: String(text.prefix(19))) else { return nil }
        if text.count > 20, let fraction = Double("0" + text.dropFirst(19)) { return base.addingTimeInterval(fraction) }
        return base
    }

    // MARK: Orientation

    /// Previews are stored unrotated: DA turns 90° counter-clockwise, BC 90° clockwise, CD 180°.
    private static func upright(_ image: CGImage, orientation: String?) -> CGImage? {
        let w = image.width, h = image.height
        let quarter = orientation == "DA" || orientation == "BC"
        guard quarter || orientation == "CD" else { return image }
        guard let context = CGContext(data: nil, width: quarter ? h : w, height: quarter ? w : h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Drawing turns the picture the way the context is turned (counter-clockwise for a positive angle).
        switch orientation {
        case "DA":
            context.translateBy(x: CGFloat(h), y: 0)
            context.rotate(by: .pi / 2)
        case "BC":
            context.translateBy(x: 0, y: CGFloat(w))
            context.rotate(by: -.pi / 2)
        default:
            context.translateBy(x: CGFloat(w), y: CGFloat(h))
            context.rotate(by: .pi)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}

// MARK: - The usual look

extension LightroomCatalog {
    /// Settings that belong to one photo, not to a look.
    private static let perPhoto: Set<String> = [
        "Exposure2012", "Temperature", "Tint", "WhiteBalance", "CropTop", "CropLeft", "CropBottom", "CropRight", "CropAngle", "HasCrop", "Orientation",
    ]

    /// The `crs` settings in a photo's develop text. Lightroom stores it as `s = { … }`; a preset file as `settings = { … }`.
    static func settings(fromDevelop text: String) -> [String: String] {
        if text.range(of: #"settings\s*=\s*\{"#, options: .regularExpression) != nil { return LightroomPresets.settings(fromTemplate: text) }
        guard let start = text.range(of: #"^\s*\w+\s*=\s*\{"#, options: .regularExpression) else { return [:] }
        return LightroomPresets.settings(fromTemplate: "settings = {" + text[start.upperBound...])
    }

    /// The most common value of each setting over these photos' edits, leaving out what is per photo
    /// (exposure, white balance, crop, masks, retouching). A setting counts only if at least half the photos set it.
    static func usualLook(_ photos: [Photo]) -> [String: String] {
        let edits = photos.compactMap { $0.develop.map(settings(fromDevelop:)) }
        guard !edits.isEmpty else { return [:] }
        var counts: [String: [String: Int]] = [:]
        for edit in edits {
            for (key, value) in edit where !perPhoto.contains(key) && !["Mask", "Local", "Retouch"].contains(where: key.hasPrefix) {
                // A nested table (a profile's own settings) comes out as "Name, =…": not a value.
                guard !value.contains("=") else { continue }
                counts[key, default: [:]][value, default: 0] += 1
            }
        }
        var look: [String: String] = [:]
        for (key, values) in counts where values.values.reduce(0, +) * 2 >= edits.count {
            // Ties go to the value that sorts first, so the result is always the same.
            if let best = values.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) { look[key] = best.key }
        }
        return look
    }
}
