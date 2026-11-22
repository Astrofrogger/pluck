import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Import: a clock offset per camera (order, folders per day, names, the sidecar's date, originals untouched),
/// RAW+JPEG as one item, and the safe-to-format state.
extension PhotoSelfTest {
    static func photoImportTest() async {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        func dir(_ name: String) -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func at(_ text: String) -> Date { PhotoImporter.parse(text)! }
        func jpeg(_ folder: URL, _ name: String, taken: String, model: String, serial: String, shade: Int) -> URL {
            let url = folder.appendingPathComponent(name)
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(shade % 256) / 255, green: CGFloat(shade / 256 % 256) / 255, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken.replacingOccurrences(of: "-", with: ":"), kCGImagePropertyExifBodySerialNumber: serial],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCo", kCGImagePropertyTIFFModel: model],
            ] as CFDictionary)
            CGImageDestinationFinalize(dest)
            return url
        }
        func copyAll(_ photos: [URL], to: URL, backup: URL? = nil, byDate: Bool = true, rename: Bool = false, offsets: [String: TimeInterval] = [:]) -> [String] {
            PhotoImporter.plan(PhotoImporter.items(photos), offsets: offsets).compactMap {
                if case .success(let path) = PhotoImporter.copy($0, to: to, backup: backup, byDate: byDate, rename: rename) { return path }
                return nil
            }
        }
        func files(_ folder: URL) -> [String] {
            (fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL).flatMap { $0.hasDirectoryPath ? nil : $0 }.map { $0.path.replacingOccurrences(of: folder.path + "/", with: "") } } ?? []).sorted()
        }

        // Two cameras, B's clock 7325 s behind the real time (A1 and B1 were the same moment).
        let card = dir("card")
        var a: [URL] = [], b: [URL] = []
        for (i, time) in ["12:00:00", "12:01:00", "12:02:00"].enumerated() {
            a.append(jpeg(card, "A\(i).JPG", taken: "2026-06-14 \(time)", model: "A1", serial: "111", shade: i))
        }
        for (i, time) in ["09:57:55", "09:59:25", "10:00:55"].enumerated() {
            b.append(jpeg(card, "B\(i).JPG", taken: "2026-06-14 \(time)", model: "B2", serial: "222", shade: 100 + i))
        }
        let cameras = PhotoImporter.cameras(in: a + b)
        check("import cameras told apart", cameras.count == 2 && cameras.map(\.photos.count) == [3, 3] && Set(cameras.map(\.key)).count == 2,
              "2 cameras of 3 photos; got \(cameras.map { "\($0.label) \($0.photos.count)" })")
        let keyB = PhotoImporter.meta(b[0]).camera?.key ?? ""
        let offsetB = at("2026-06-14 12:00:00").timeIntervalSince(at("2026-06-14 09:57:55"))
        let raw = PhotoImporter.plan(PhotoImporter.items(a + b), offsets: [:]).map(\.item.primary.lastPathComponent)
        let fixed = PhotoImporter.plan(PhotoImporter.items(a + b), offsets: [keyB: offsetB]).map(\.item.primary.lastPathComponent)
        check("import clock offset orders two cameras", raw == ["B0.JPG", "B1.JPG", "B2.JPG", "A0.JPG", "A1.JPG", "A2.JPG"]
              && fixed == ["A0.JPG", "B0.JPG", "A1.JPG", "B1.JPG", "A2.JPG", "B2.JPG"], "unshifted B first, shifted interleaved; got \(raw) / \(fixed)")

        // By-date folders and names follow the shifted time; the originals stay as they are.
        let late = dir("late")
        let night = jpeg(late, "N.JPG", taken: "2026-06-14 23:59:50", model: "C3", serial: "333", shade: 7)
        let keyC = PhotoImporter.meta(night).camera?.key ?? ""
        let before = try? Data(contentsOf: night)
        let plain = dir("out-plain"), shifted = dir("out-shifted"), named = dir("out-named")
        _ = copyAll([night], to: plain)
        let moved = copyAll([night], to: shifted, offsets: [keyC: 60])
        _ = copyAll([night], to: named, byDate: false, rename: true, offsets: [keyC: 60])
        check("import by-date folder follows the offset", files(plain).contains("2026/2026-06-14/N.JPG") && files(shifted).contains("2026/2026-06-15/N.JPG"),
              "06-14 without, 06-15 with; got \(files(plain)) / \(files(shifted))")
        check("import rename uses the shifted time", files(named).contains("20260615-000050-N.JPG"), "20260615-000050-N.JPG; got \(files(named))")
        let dateInSidecar = moved.first.flatMap { PhotoImporter.sidecarDate(URL(fileURLWithPath: $0)) }
        check("import sidecar carries the shifted date", dateInSidecar == at("2026-06-15 00:00:50")
              && moved.first.map { PhotoImporter.captureDate(URL(fileURLWithPath: $0)) } == at("2026-06-15 00:00:50"),
              "2026-06-15 00:00:50; got \(String(describing: dateInSidecar))")
        check("import originals untouched", (try? Data(contentsOf: night)) == before && files(late) == ["N.JPG"]
              && !files(plain).contains { $0.hasSuffix(".xmp") }, "same bytes, no sidecar beside it or without an offset; got \(files(late)) / \(files(plain))")

        // A sidecar from another app: its date wins over the file's, and its rating survives the shift.
        let side = dir("side")
        let rated = jpeg(side, "R.JPG", taken: "2026-06-14 10:00:00", model: "C3", serial: "333", shade: 9)
        var record = PhotoRecord()
        record.rating = 4
        try? PhotoXMP.write(rated.path, record: record)
        let keptRating = copyAll([rated], to: dir("out-side"), offsets: [keyC: 3600]).first.flatMap { PhotoXMP.read($0)?.rating }
        check("import offset keeps the sidecar's rating", keptRating == 4, "4; got \(String(describing: keptRating))")
        try? PhotoXMP.writeDate(rated.path, taken: "2026-06-20T12:00:00", offset: 0)
        check("import reads a sidecar's date first", PhotoImporter.captureDate(rated) == at("2026-06-20 12:00:00"),
              "2026-06-20 12:00:00; got \(PhotoImporter.captureDate(rated))")

        // RAW+JPEG: one item, copied, renamed and skipped together.
        let pair = dir("pair")
        let pj = jpeg(pair, "IMG_1.JPG", taken: "2026-06-14 12:00:00", model: "A1", serial: "111", shade: 20)
        let raw1 = pair.appendingPathComponent("IMG_1.CR3")
        try? Data("raw one".utf8).write(to: raw1)
        try? Data("<x/>".utf8).write(to: pair.appendingPathComponent("IMG_1.xmp"))
        let single = jpeg(pair, "IMG_2.JPG", taken: "2026-06-14 12:05:00", model: "A1", serial: "111", shade: 21)
        let items = PhotoImporter.items([pj, single, raw1])
        check("import raw+jpeg is one item", PhotoImporter.isRaw(raw1) && items.count == 2 && items[0].primary == raw1 && items[0].companions == [pj]
              && items[1].companions.isEmpty, "2 items, RAW the photo, JPEG beside it; got \(items)")
        let out = dir("out-pair")
        let first = copyAll([pj, single, raw1], to: out)
        check("import copies both together", files(out) == ["2026/2026-06-14/IMG_1.CR3", "2026/2026-06-14/IMG_1.JPG", "2026/2026-06-14/IMG_1.xmp", "2026/2026-06-14/IMG_2.JPG"]
              && first.count == 2 && first[0].hasSuffix("IMG_1.CR3"), "RAW, JPEG, sidecar, IMG_2; got \(files(out)) \(first)")
        _ = copyAll([pj, single, raw1], to: out)
        check("import skips both together", files(out).count == 4, "still 4 files; got \(files(out))")
        // Another card's IMG_1 pair (other content): both kept as -2.
        let other = dir("pair2")
        let oj = jpeg(other, "IMG_1.JPG", taken: "2026-06-14 12:00:00", model: "B2", serial: "222", shade: 40)
        let oraw = other.appendingPathComponent("IMG_1.CR3")
        try? Data("raw two".utf8).write(to: oraw)
        try? Data("<y/>".utf8).write(to: other.appendingPathComponent("IMG_1.xmp"))
        _ = copyAll([oj, oraw], to: out)
        let list = files(out)
        check("import second pair kept as -2 together", list.contains("2026/2026-06-14/IMG_1-2.CR3") && list.contains("2026/2026-06-14/IMG_1-2.JPG")
              && list.contains("2026/2026-06-14/IMG_1-2.xmp") && list.count == 8 - 1, "pair as -2 with its own sidecar; got \(list)")
        let renamed = dir("out-pair-renamed")
        _ = copyAll([pj, raw1], to: renamed, byDate: false, rename: true)
        check("import renames a pair alike", files(renamed) == ["20260614-120000-IMG_1.CR3", "20260614-120000-IMG_1.JPG", "20260614-120000-IMG_1.xmp"],
              "same stamp on both; got \(files(renamed))")

        // Safe to format: only when every photo is in every copy and read back identical.
        let good = dir("good-main"), goodBackup = dir("good-backup")
        var clean = PhotoImporter.Report(total: 3, copies: 2)
        for planned in PhotoImporter.plan(PhotoImporter.items(a), offsets: [:]) {
            _ = clean.add(PhotoImporter.copy(planned, to: good, backup: goodBackup, byDate: false, rename: false), planned.item.primary.lastPathComponent)
        }
        check("import safe to format when every copy matched", clean.safe && clean.copied == 3 && clean.copies == 2 && files(goodBackup).count == 3,
              "safe, 3 photos in 2 copies; got \(clean) \(files(goodBackup))")
        let bad = dir("bad-main"), badBackup = dir("bad-backup")
        PhotoImporter.afterCopy = { copy in
            guard copy.path.contains("/bad-backup/"), copy.lastPathComponent.contains("A1.JPG"), let handle = try? FileHandle(forWritingTo: copy) else { return }
            try? handle.seekToEnd(); try? handle.write(contentsOf: Data([0])); try? handle.close()
        }
        var dirty = PhotoImporter.Report(total: 3, copies: 2)
        for planned in PhotoImporter.plan(PhotoImporter.items(a), offsets: [:]) {
            _ = dirty.add(PhotoImporter.copy(planned, to: bad, backup: badBackup, byDate: false, rename: false), planned.item.primary.lastPathComponent)
        }
        PhotoImporter.afterCopy = nil
        check("import one corrupted copy is not safe to format", !dirty.safe && dirty.failed == ["A1.JPG"] && dirty.copied == 2
              && !fm.fileExists(atPath: badBackup.appendingPathComponent("A1.JPG").path) && files(badBackup).count == 2,
              "not safe, A1.JPG failed, bad copy removed (no part file left); got \(dirty) \(files(badBackup))")
        check("import nothing found is not safe", !PhotoImporter.Report(total: 0).safe, "not safe")

        // A JPEG-only IMG_0001 from camera B where camera A's RAW-only IMG_0001.CR3 + .xmp already are: another
        // photo, so -2 with its own sidecar and date; A's sidecar untouched. The same A again isn't copied twice.
        let camA = dir("camA"), camB = dir("camB"), mixed = dir("out-mixed")
        let ar = camA.appendingPathComponent("IMG_0001.CR3")
        try? Data("raw A".utf8).write(to: ar)
        try? Data("<a/>".utf8).write(to: camA.appendingPathComponent("IMG_0001.xmp"))
        _ = copyAll([ar], to: mixed, byDate: false)
        let bj = jpeg(camB, "IMG_0001.JPG", taken: "2026-06-14 15:00:00", model: "B2", serial: "222", shade: 61)
        try? Data("<b/>".utf8).write(to: camB.appendingPathComponent("IMG_0001.xmp"))
        let bPath = copyAll([bj], to: mixed, byDate: false, offsets: [PhotoImporter.meta(bj).camera?.key ?? "": 60]).first ?? ""
        _ = copyAll([ar], to: mixed, byDate: false)
        let aSide = try? Data(contentsOf: mixed.appendingPathComponent("IMG_0001.xmp"))
        check("import JPEG-only photo beside another camera's RAW is -2", bPath.hasSuffix("/IMG_0001-2.JPG")
              && files(mixed) == ["IMG_0001-2.JPG", "IMG_0001-2.xmp", "IMG_0001.CR3", "IMG_0001.xmp"] && aSide == Data("<a/>".utf8)
              && PhotoImporter.captureDate(URL(fileURLWithPath: bPath)) == at("2026-06-14 15:01:00"),
              "B as -2 with its own sidecar and date, A's sidecar unchanged; got \(bPath) \(files(mixed)) B \(PhotoImporter.captureDate(URL(fileURLWithPath: bPath)))")
        // A leftover sidecar alone (no photo) isn't taken as this photo's either.
        let orphan = dir("out-orphan")
        try? Data("<o/>".utf8).write(to: orphan.appendingPathComponent("IMG_0001.xmp"))
        check("import a lone sidecar of the same name is another photo's", copyAll([bj], to: orphan, byDate: false).first?.hasSuffix("/IMG_0001-2.JPG") == true,
              "-2; got \(files(orphan))")

        // Never over a file that's there; a copy is named only once checked.
        let spot = dir("excl").appendingPathComponent("X.JPG")
        try? Data("theirs".utf8).write(to: spot)
        let refused = (try? PhotoImporter.copyChecked(bj, to: spot)) == nil
        check("import copy never replaces a file", refused && (try? Data(contentsOf: spot)) == Data("theirs".utf8) && files(spot.deletingLastPathComponent()) == ["X.JPG"],
              "refused, theirs kept, no part file; got \(files(spot.deletingLastPathComponent()))")

        // Safe to format only when nothing else is on the card: a hybrid card's clips and sound stay there.
        let hybrid = dir("hybrid")
        let shots = dir("hybrid/DCIM/100CAM")
        let hp = jpeg(shots, "IMG_5.JPG", taken: "2026-06-14 12:00:00", model: "A1", serial: "111", shade: 70)
        let hr = shots.appendingPathComponent("IMG_5.CR3")
        try? Data("raw 5".utf8).write(to: hr)
        try? fm.createDirectory(at: hybrid.appendingPathComponent("PRIVATE/M4ROOT/CLIP"), withIntermediateDirectories: true)
        try? Data("clip".utf8).write(to: hybrid.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        try? Data("wav".utf8).write(to: shots.appendingPathComponent("IMG_5.WAV"))
        try? Data("x".utf8).write(to: hybrid.appendingPathComponent(".Spotlight-V100"))
        try? Data("x".utf8).write(to: shots.appendingPathComponent(".hidden"))
        let hybridItems = PhotoImporter.items([hp, hr])
        let left = PhotoImporter.leftOnCards([hybrid], items: hybridItems)
        var mixedReport = PhotoImporter.Report(total: 1, copies: 1)
        mixedReport.left = left
        _ = mixedReport.add(PhotoImporter.copy(PhotoImporter.plan(hybridItems, offsets: [:])[0], to: dir("out-hybrid"), backup: nil, byDate: false, rename: false), "IMG_5.CR3")
        check("import a card with videos is not safe to format", left == ["DCIM/100CAM/IMG_5.WAV", "PRIVATE/M4ROOT/CLIP/C0001.MP4"] && !mixedReport.safe && mixedReport.copied == 1,
              "the clip and the sound left, not safe; got \(left) \(mixedReport)")
        try? fm.removeItem(at: hybrid.appendingPathComponent("PRIVATE"))
        try? fm.removeItem(at: shots.appendingPathComponent("IMG_5.WAV"))
        check("import a photo-only card has nothing left", PhotoImporter.leftOnCards([hybrid], items: hybridItems).isEmpty,
              "nothing; got \(PhotoImporter.leftOnCards([hybrid], items: hybridItems))")

        // Set the Real Time: the picked minute with the camera's seconds (no minute's jump forward).
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let shift = PhotoImporter.offset(realTime: at("2026-06-14 14:05:50"), cameraTime: at("2026-06-14 12:00:37"), calendar: utc)
        check("import real time keeps the camera's seconds", shift == 2 * 3600 + 5 * 60, "7500 s; got \(shift)")
    }
    /// Fixtures for the import sheet's snapshots: two cameras (one clock two hours off) and a RAW+JPEG pair,
    /// under ~/.pluck-test/shots407b/wf-photo/cards (a fresh copy each time).
    static func photoImportFixtures() async {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent().appendingPathComponent("shots407b/wf-photo/cards", isDirectory: true)
        try? fm.removeItem(at: root)
        for (folder, model, serial, hour) in [("Camera A", "Alpha 7", "1001", 12), ("Camera B", "Zeta X", "2002", 10)] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 0..<4 {
                let url = dir.appendingPathComponent("IMG_\(1000 + i).JPG")
                let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(red: CGFloat(i) / 4, green: hour == 12 ? 0.4 : 0.7, blue: 0.5, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
                let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:06:14 \(hour):0\(i):00", kCGImagePropertyExifBodySerialNumber: serial],
                    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sample", kCGImagePropertyTIFFModel: model],
                ] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }
        // A RAW beside its JPEG on camera A: one photo.
        try? Data("raw".utf8).write(to: root.appendingPathComponent("Camera A/IMG_1000.CR3"))
        check("import snapshot fixtures", PhotoCatalog.photos(in: [root]).count == 9, "9 files; got \(PhotoCatalog.photos(in: [root]).count)")
    }
}
