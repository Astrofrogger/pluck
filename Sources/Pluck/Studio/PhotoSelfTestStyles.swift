import AppKit
import ImageIO
import SQLite3
import UniformTypeIdentifiers

/// The Lightroom catalog reader (Edit Like Me, part 1), on a tiny made-up catalog and previews folder.
extension PhotoSelfTest {
    static func catalogReader() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-lrcat-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Catalog")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = folder.appendingPathComponent("Test.lrcat")
        buildFixtureCatalog(catalogURL)

        // Lightroom is "open": a -wal file sits next to the catalog.
        try? Data().write(to: URL(fileURLWithPath: catalogURL.path + "-wal"))
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        func modified() -> Date? { (try? FileManager.default.attributesOfItem(atPath: catalogURL.path))?[.modificationDate] as? Date }
        let namesBefore = listing(), dateBefore = modified()

        guard let catalog = try? LightroomCatalog(url: catalogURL) else {
            check("catalog reads collections", false, "could not open the fixture")
            check("catalog reads previews", false, "could not open the fixture")
            check("catalog stays untouched", false, "could not open the fixture")
            return
        }
        let collections = catalog.collections()
        check("catalog reads collections", collections.count == 1 && collections[0].photos == 6 && collections[0].keepers == 3,
              "1 collection with 6 photos, 3 keepers; got \(collections)")

        let photos = collections.first.map { catalog.photos(in: $0.id) } ?? []
        let turned = photos.first { $0.orientation == "DA" }
        let preview = turned.flatMap { catalog.preview(of: $0, longSide: 30) }
        let upright = photos.first { $0.orientation == "AB" }.flatMap { catalog.preview(of: $0, longSide: 10) }
        let first = photos.first { $0.id == 1 }
        let shutter = first?.shutter ?? 0
        check("catalog reads previews", preview?.width == 20 && preview?.height == 40 && upright?.width == 20 && upright?.height == 10
              && first?.original?.path == "/Volumes/Shoots/2024/Wedding/IMG_0001.CR3" && first?.develop == "settings = { Exposure2012 = 0.5 }"
              && abs(shutter - 0.01) < 0.0001,
              "turned preview 20x40, upright 20x10, original, develop, shutter 0.01; got \(preview?.width ?? 0)x\(preview?.height ?? 0), "
              + "\(upright?.width ?? 0)x\(upright?.height ?? 0), \(String(describing: first?.original?.path)), \(String(describing: first?.develop)), \(shutter)")

        check("catalog stays untouched", listing() == namesBefore && modified() == dateBefore && !photos.isEmpty,
              "same files and date; got \(listing()) vs \(namesBefore), \(String(describing: modified())) vs \(String(describing: dateBefore))")
    }

    /// The catalog tables and columns Pluck reads.
    private static let fixtureSchema = """
            CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT);
            CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, rootFolder INTEGER, pathFromRoot TEXT);
            CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, folder INTEGER, baseName TEXT, extension TEXT);
            CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rootFile INTEGER, captureTime TEXT, rating REAL, orientation TEXT);
            CREATE TABLE Adobe_imageDevelopSettings (id_local INTEGER PRIMARY KEY, image INTEGER, text TEXT);
            CREATE TABLE AgHarvestedExifMetadata (id_local INTEGER PRIMARY KEY, image INTEGER, shutterSpeed REAL, isoSpeedRating REAL, focalLength REAL);
            CREATE TABLE AgLibraryCollection (id_local INTEGER PRIMARY KEY, name TEXT, creationId TEXT);
            CREATE TABLE AgLibraryCollectionImage (id_local INTEGER PRIMARY KEY, collection INTEGER, image INTEGER);
            """

    private static let previewsSchema = """
        CREATE TABLE ImageCacheEntry (imageId INTEGER PRIMARY KEY, uuid TEXT, digest TEXT, orientation TEXT);
        CREATE TABLE PyramidLevel (uuid TEXT, level INTEGER, width INTEGER, height INTEGER);

        """

    /// Two collections over 10 photos: one with 6 photos (3 rated), one with 4 and none rated.
    private static func buildFixtureCatalog(_ url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var sql = fixtureSchema + """
            INSERT INTO AgLibraryRootFolder VALUES (1, '/Volumes/Shoots/');
            INSERT INTO AgLibraryFolder VALUES (1, 1, '2024/Wedding/');
            INSERT INTO AgLibraryCollection VALUES (1, 'Picks', 'com.adobe.ag.library.collection');
            INSERT INTO AgLibraryCollection VALUES (2, 'Unrated', 'com.adobe.ag.library.collection');
            INSERT INTO AgLibraryCollection VALUES (3, 'Smart', 'com.adobe.ag.library.smart_collection');
            """
        let ratings = [5, 3, 1, 0, 0, 0, 0, 0, 0, 0]
        for id in 1...10 {
            let orientation = id == 1 ? "DA" : id == 2 ? "BC" : "AB"
            // shutter 6.643856 is APEX for 1/100 s.
            sql += """
                INSERT INTO AgLibraryFile VALUES (\(id), 1, 'IMG_\(String(format: "%04d", id))', 'CR3');
                INSERT INTO Adobe_images VALUES (\(id), \(id), '2024-05-01T12:\(String(format: "%02d", id)):00', \(ratings[id - 1]), '\(orientation)');
                INSERT INTO Adobe_imageDevelopSettings VALUES (\(id), \(id), 'settings = { Exposure2012 = 0.5 }');
                INSERT INTO AgHarvestedExifMetadata VALUES (\(id), \(id), 6.643856, 200, 50);
                INSERT INTO AgLibraryCollectionImage VALUES (\(id), \(id <= 6 ? 1 : 2), \(id));
                """
            sql += "\n"
        }
        sqlite3_exec(db, sql, nil, nil, nil)

        // Previews: images 1 (turned) and 2 are 40x20 stored unrotated, in two sizes; the rest are 20x10.
        let previews = url.deletingLastPathComponent().appendingPathComponent("Test Previews.lrdata")
        var pdb: OpaquePointer?
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        guard sqlite3_open_v2(previews.appendingPathComponent("previews.db").path, &pdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(pdb) }
        var psql = previewsSchema
        for id in 1...10 {
            let uuid = String(format: "A%07X-0000-4000-8000-%012X", id, id), digest = "d\(id)"
            psql += "INSERT INTO ImageCacheEntry VALUES (\(id), '\(uuid)', '\(digest)', 'AB');\n"
            let sizes = id <= 2 ? [(20, 10), (40, 20)] : [(20, 10)]
            let folder = previews.appendingPathComponent(String(uuid.prefix(1))).appendingPathComponent(String(uuid.prefix(4)))
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, size) in sizes.enumerated() {
                psql += "INSERT INTO PyramidLevel VALUES ('\(uuid)', \(index + 1), \(size.0), \(size.1));\n"
                writeJPEG(width: size.0, height: size.1, to: folder.appendingPathComponent("\(uuid)-\(digest)_\(size.0)"))
            }
        }
        sqlite3_exec(pdb, psql, nil, nil, nil)
    }

    private static func writeJPEG(width: Int, height: Int, to url: URL) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = { context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return context.makeImage() }(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// Styles (Edit Like Me, part 1): training on a made-up catalog of 4 collections × 40 photos. Each moment
/// is 4 frames of one drawn scene a second apart; the kept frame is sharp, the 3 dropped ones blurred.
extension PhotoSelfTest {
    static func styles() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-styles-\(UUID().uuidString)")
        let full = root.appendingPathComponent("Full"), gaps = root.appendingPathComponent("Gaps")
        try? FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        let catalogURL = full.appendingPathComponent("Styles.lrcat")
        buildStyleCatalog(catalogURL)
        // A copy with 5 previews gone (another path, so nothing comes from the first one's cache).
        try? FileManager.default.copyItem(at: full, to: gaps)
        let gapsURL = gaps.appendingPathComponent("Styles.lrcat")
        let gone = (1...5).map { previewFile(of: $0, in: gapsURL) }
        for file in gone { try? FileManager.default.removeItem(at: file) }
        var made: [PhotoStyle] = []
        defer {
            for style in made { PhotoStyles.shared.remove(style) }
            for url in [catalogURL, gapsURL] { try? FileManager.default.removeItem(at: LightroomCatalog.cacheFolder(for: url)) }
            try? FileManager.default.removeItem(at: root)
        }

        let start = Date()
        let style = PhotoStyle(name: "Test", catalog: catalogURL, collections: [1, 2, 3, 4])
        let trained = try? await PhotoStyleTrainer.train(style, iterations: 30) { _ in }
        let took = Date().timeIntervalSince(start)
        if let trained { made.append(trained); PhotoStyles.shared.update(trained) }
        let covered = trained?.covered ?? -1, shown = trained?.shown ?? -1
        check("style trains", trained?.trained != nil && (0...1).contains(covered) && (0.2...0.5).contains(shown) && trained?.photos == 160 && trained?.skipped == 0,
              "trained on 160 photos, covered in 0…1, shown in 0.2…0.5; got \(String(describing: trained?.photos)) photos, covered \(covered), shown \(shown) in \(String(format: "%.1f", took)) s")

        // A moment it has never seen: the sharp frame should rank above its blurred twin.
        var scores: [Double] = []
        if let trained {
            let sharp = styleScene(999, blur: 1), soft = styleScene(999, blur: 5)
            func measured(_ image: CGImage?) -> PhotoCheck? {
                guard let image else { return nil }
                let signals = PhotoSignals.measure(image, exif: nil)
                return PhotoCheck(sharpness: signals.sharpness ?? 0, faces: [], eyesClosed: false, taken: nil, signals: signals)
            }
            let checks = ["sharp": measured(sharp), "soft": measured(soft)].compactMapValues { $0 }
            scores = PhotoRanker(style: trained).scores(["soft", "sharp"], checks: checks)
        }
        check("style ranks like its keepers", scores.count == 2 && scores[1] > scores[0] && PhotoStyles.shared.model(for: trained ?? style) != nil,
              "sharp above blurred; got \(scores)")

        let partial = try? await PhotoStyleTrainer.train(PhotoStyle(name: "Gaps", catalog: gapsURL, collections: [1, 2, 3, 4]), iterations: 30) { _ in }
        if let partial { made.append(partial) }
        check("missing previews are skipped", partial?.skipped == 5 && partial?.photos == 155 && partial?.trained != nil,
              "5 skipped, 155 learned; got \(String(describing: partial?.skipped)), \(String(describing: partial?.photos))")
    }

    /// 4 collections of 10 moments × 4 frames. Moments are 3 minutes apart, frames 1 s apart; one frame per moment is kept.
    private static func buildStyleCatalog(_ url: URL) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        var sql = fixtureSchema + """
            INSERT INTO AgLibraryRootFolder VALUES (1, '/Volumes/Shoots/');
            INSERT INTO AgLibraryFolder VALUES (1, 1, 'Events/');

            """
        let previews = url.deletingLastPathComponent().appendingPathComponent("Styles Previews.lrdata")
        try? FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        var psql = previewsSchema
        for collection in 1...4 {
            sql += "INSERT INTO AgLibraryCollection VALUES (\(collection), 'Event \(collection)', 'com.adobe.ag.library.collection');\n"
            for moment in 0..<10 {
                let keeper = moment % 4
                for frame in 0..<4 {
                    let id = (collection - 1) * 40 + moment * 4 + frame + 1
                    let time = String(format: "2024-06-%02dT10:%02d:%02d", collection, moment * 3, frame)
                    sql += """
                        INSERT INTO AgLibraryFile VALUES (\(id), 1, 'IMG_\(String(format: "%04d", id))', 'JPG');
                        INSERT INTO Adobe_images VALUES (\(id), \(id), '\(time)', \(frame == keeper ? 1 + moment % 5 : 0), 'AB');
                        INSERT INTO AgHarvestedExifMetadata VALUES (\(id), \(id), 7.643856, 400, 35);
                        INSERT INTO AgLibraryCollectionImage VALUES (\(id), \(collection), \(id));

                        """
                    let uuid = String(format: "B%07X-0000-4000-8000-%012X", id, id)
                    psql += "INSERT INTO ImageCacheEntry VALUES (\(id), '\(uuid)', 'd\(id)', 'AB');\n"
                    let file = previewFile(of: id, in: url)
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let image = styleScene(collection * 100 + moment, blur: frame == keeper ? 1 : 3 + frame, shift: frame) { writeJPEG(image, to: file) }
                }
            }
        }
        sqlite3_exec(db, sql, nil, nil, nil)
        var pdb: OpaquePointer?
        guard sqlite3_open_v2(previews.appendingPathComponent("previews.db").path, &pdb, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(pdb) }
        sqlite3_exec(pdb, psql, nil, nil, nil)
    }

    /// A style fixture photo's preview file (one 512 px level).
    private static func previewFile(of id: Int, in catalog: URL) -> URL {
        let uuid = String(format: "B%07X-0000-4000-8000-%012X", id, id)
        return catalog.deletingLastPathComponent().appendingPathComponent("Styles Previews.lrdata")
            .appendingPathComponent(String(uuid.prefix(1))).appendingPathComponent(String(uuid.prefix(4)))
            .appendingPathComponent("\(uuid)-d\(id)_512")
    }

    /// A made-up scene: shapes and a simple face, the same for a seed. `blur` > 1 draws it that many times
    /// smaller and scales it back up (soft); `shift` nudges it a few pixels, as a hand-held burst would.
    private static func styleScene(_ seed: Int, blur: Int, shift: Int = 0) -> CGImage? {
        let width = 512, height = 384
        var state = UInt64(seed) &* 0x9E3779B97F4A7C15 &+ 1
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        let small = max(1, blur)
        guard let context = CGContext(data: nil, width: width / small, height: height / small, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 1 / CGFloat(small), y: 1 / CGFloat(small))
        context.translateBy(x: CGFloat(shift * 3), y: CGFloat(shift * 2))
        context.setFillColor(CGColor(gray: 0.3 + 0.4 * random(), alpha: 1))
        context.fill(CGRect(x: -20, y: -20, width: width + 40, height: height + 40))
        for _ in 0..<14 {
            context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            let rect = CGRect(x: random() * CGFloat(width), y: random() * CGFloat(height), width: 20 + random() * 120, height: 20 + random() * 120)
            if random() > 0.5 { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }
        // A face: skin, two eyes and a mouth.
        let face = CGRect(x: 150 + random() * 150, y: 100 + random() * 100, width: 110, height: 140)
        context.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.6, alpha: 1))
        context.fillEllipse(in: face)
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fillEllipse(in: CGRect(x: face.minX + 25, y: face.midY + 15, width: 18, height: 12))
        context.fillEllipse(in: CGRect(x: face.maxX - 43, y: face.midY + 15, width: 18, height: 12))
        context.fill(CGRect(x: face.midX - 25, y: face.minY + 35, width: 50, height: 6))
        guard let drawn = context.makeImage(), small > 1 else { return context.makeImage() }
        guard let big = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        big.interpolationQuality = .high
        big.draw(drawn, in: CGRect(x: 0, y: 0, width: width, height: height))
        return big.makeImage()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// The usual look of a style's keepers (Edit Like Me, part 1).
extension PhotoSelfTest {
    static func usualLook() {
        func photo(_ id: Int, _ develop: String?) -> LightroomCatalog.Photo {
            LightroomCatalog.Photo(id: id, captureTime: nil, rating: 1, orientation: nil, develop: develop, original: nil)
        }
        // Lightroom's own text (`s = { … }`, a curve, a nested profile) and a preset's (`settings = { … }`).
        let keepers = [
            photo(1, "s = {\n\tAutoLateralCA = 0,\n\tContrast2012 = 20,\n\tExposure2012 = 0.5,\n\tTemperature = 5200,\n\tVibrance = 30,\n\tCropTop = 0.1,\n"
                  + "\tMaskGroupBasedCorrections = 1,\n\tToneCurvePV2012 = {\n\t\t0,\n\t\t0,\n\t\t255,\n\t\t255,\n\t},\n\tLook = {\n\t\tName = \"Warm\",\n\t},\n}"),
            photo(2, "s = { Contrast2012 = 20, Exposure2012 = -0.3, Temperature = 6100, Saturation = -5, }"),
            photo(3, "settings = { Contrast2012 = 10, Exposure2012 = 1, Saturation = -5 }"),
        ]
        let look = LightroomCatalog.usualLook(keepers)
        check("usual look from keepers", look["Contrast2012"] == "20" && look["Exposure2012"] == nil && look["Temperature"] == nil
              && look["Vibrance"] == nil && look["CropTop"] == nil && look["MaskGroupBasedCorrections"] == nil && look["Look"] == nil
              && look["Saturation"] == "-5" && look["ToneCurvePV2012"] == nil && look["AutoLateralCA"] == nil,
              "Contrast2012 20, Saturation -5, no exposure, white balance, crop, mask or Vibrance; got \(look)")
        check("usual look needs edits", LightroomCatalog.usualLook([photo(4, nil)]).isEmpty && LightroomCatalog.usualLook([]).isEmpty, "empty")
    }
}
