import Vision
import ImageIO
import CoreImage
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

/// Smart albums, the Map and People.
extension PhotoSelfTest {
    private static func scratch(_ name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Smart albums

    static func smartAlbums() async {
        // The rules, one by one.
        var record = PhotoRecord()
        record.rating = 4
        record.flag = .pick
        record.label = "green"
        record.meta = PhotoMeta()
        record.meta?.keywords = ["Wedding", "Ghent"]
        let now = Date.now
        let person = UUID()
        let facts = SmartRule.Facts(record: record, fact: PhotoFact(camera: "Canon EOS R6", lens: "RF 50mm F1.2 L USM", taken: now.addingTimeInterval(-86400 * 3)),
                                    check: nil, labels: ["beach"], people: [person])
        func rule(_ field: SmartRule.Field, _ change: (inout SmartRule) -> Void = { _ in }) -> SmartRule {
            var rule = SmartRule(field: field)
            change(&rule)
            return rule
        }
        let cases: [(String, SmartRule, String, Bool)] = [
            ("rating at least", rule(.rating) { $0.number = 3 }, "a.jpg", true),
            ("rating at least, too few", rule(.rating) { $0.number = 5 }, "a.jpg", false),
            ("rating exactly", rule(.rating) { $0.number = 4; $0.exact = true }, "a.jpg", true),
            ("rating exactly, other", rule(.rating) { $0.number = 3; $0.exact = true }, "a.jpg", false),
            ("flag pick", rule(.flag) { $0.text = "pick" }, "a.jpg", true),
            ("flag reject", rule(.flag) { $0.text = "reject" }, "a.jpg", false),
            ("label", rule(.label) { $0.text = "green" }, "a.jpg", true),
            ("label other", rule(.label) { $0.text = "red" }, "a.jpg", false),
            ("keyword", rule(.keyword) { $0.text = "wedd" }, "a.jpg", true),
            ("keyword from tags", rule(.keyword) { $0.text = "Beach" }, "a.jpg", true),
            ("keyword missing", rule(.keyword) { $0.text = "dog" }, "a.jpg", false),
            ("camera", rule(.camera) { $0.text = "eos r6" }, "a.jpg", true),
            ("camera other", rule(.camera) { $0.text = "Sony" }, "a.jpg", false),
            ("lens", rule(.lens) { $0.text = "50mm" }, "a.jpg", true),
            ("file raw", rule(.fileType) { $0.text = "raw" }, "a.CR3", true),
            ("file raw not jpeg", rule(.fileType) { $0.text = "raw" }, "a.jpg", false),
            ("file jpeg", rule(.fileType) { $0.text = "jpeg" }, "a.JPG", true),
            ("file dng", rule(.fileType) { $0.text = "dng" }, "a.dng", true),
            ("file heic", rule(.fileType) { $0.text = "heic" }, "a.HEIC", true),
            ("edited no", rule(.edited) { $0.yes = false }, "a.jpg", true),
            ("edited yes", rule(.edited), "a.jpg", false),
            ("faces", rule(.faces), "a.jpg", true),
            ("no faces", rule(.faces) { $0.yes = false }, "a.jpg", false),
            ("person", rule(.person) { $0.text = person.uuidString }, "a.jpg", true),
            ("other person", rule(.person) { $0.text = UUID().uuidString }, "a.jpg", false),
            ("this year", rule(.date) { $0.text = "year" }, "a.jpg", Calendar.current.isDate(now.addingTimeInterval(-86400 * 3), equalTo: now, toGranularity: .year)),
            ("last 30 days", rule(.date) { $0.text = "month" }, "a.jpg", true),
            ("between", rule(.date) { $0.text = "between"; $0.from = now.addingTimeInterval(-86400 * 5); $0.to = now.addingTimeInterval(-86400 * 3) }, "a.jpg", true),
            ("between, outside", rule(.date) { $0.text = "between"; $0.from = now.addingTimeInterval(-86400 * 2); $0.to = now }, "a.jpg", false),
        ]
        let wrong = cases.filter { $0.1.matches($0.2, facts, now: now) != $0.3 }.map(\.0)
        check("smart rules", wrong.isEmpty, "every rule as expected; wrong: \(wrong)")
        let old = SmartRule.Facts(record: record, fact: PhotoFact(taken: now.addingTimeInterval(-86400 * 60)))
        check("smart last 30 days leaves older", !rule(.date) { $0.text = "month" }.matches("a.jpg", old, now: now), "60 days ago is out")

        // In the catalogue: live, all or any, saved in its file and gone again when deleted.
        let folder = scratch("smart")
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let source = (try? FileManager.default.contentsOfDirectory(atPath: photos))?.first(where: { $0.lowercased().hasSuffix(".jpg") }) else {
            return check("smart fixture", false, "a JPEG in the photos folder")
        }
        let a = folder.appendingPathComponent("A.jpg").path, b = folder.appendingPathComponent("B.jpg").path
        try? FileManager.default.copyItem(atPath: (photos as NSString).appendingPathComponent(source), toPath: a)
        try? FileManager.default.copyItem(atPath: a, toPath: b)
        let catalog = PhotoCatalog.shared
        let holder = catalog.newAlbum(named: "Smart test", with: [a, b])
        catalog.update([a]) { $0.rating = 5 }
        catalog.update([b]) { $0.rating = 2; $0.flag = .reject }
        var album = SmartAlbum(name: "Best", rules: [rule(.rating) { $0.number = 4 }, rule(.flag) { $0.text = "reject" }])
        catalog.save(smart: album)
        let mine = { catalog.photos(in: .smart(album.id)).filter { $0 == a || $0 == b } }
        check("smart album all", mine() == [], "nothing is both 4+ and rejected; got \(mine())")
        album.matchAll = false
        catalog.save(smart: album)
        check("smart album any", mine() == [a, b], "A and B; got \(mine())")
        album.rules = [rule(.rating) { $0.number = 4 }]
        catalog.save(smart: album)
        check("smart album one rule", mine() == [a], "A; got \(mine())")
        catalog.update([b]) { $0.rating = 5 }
        check("smart album follows changes", mine() == [a, b], "B joins once rated 5; got \(mine())")
        let key = PhotoCatalog.Source.smart(album.id).key
        check("smart album source key", PhotoCatalog.Source(key: key) == .smart(album.id), key)
        catalog.saveNow()
        let saved = (try? String(contentsOf: URL(fileURLWithPath: UserDefaults.standard.string(forKey: "PluckScreenshotCatalog") ?? ""), encoding: .utf8)) ?? ""
        check("smart album saved", saved.contains("\"smartAlbums\"") && saved.contains(album.id.uuidString), "in the catalogue file")
        catalog.deleteSmartAlbum(album.id)
        catalog.deleteAlbum(holder.id)
        catalog.saveNow()
        let after = (try? String(contentsOf: URL(fileURLWithPath: UserDefaults.standard.string(forKey: "PluckScreenshotCatalog") ?? ""), encoding: .utf8)) ?? ""
        check("no smart albums, no key", !after.contains("smartAlbums"), "a catalogue without them saves as before")
    }

    // MARK: - Map

    /// A small JPEG with a place in its EXIF (nil: none).
    private static func writeJPEG(_ url: URL, latitude: Double?, longitude: Double?) {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        var properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sony", kCGImagePropertyTIFFModel: "ILCE-7M4"]]
        if let latitude, let longitude {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(latitude), kCGImagePropertyGPSLatitudeRef: latitude < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(longitude), kCGImagePropertyGPSLongitudeRef: longitude < 0 ? "W" : "E",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    static func map() async {
        let folder = scratch("map")
        defer { try? FileManager.default.removeItem(at: folder) }
        let places: [(String, Double?, Double?)] = [("ghent.jpg", 51.0543, 3.7174), ("ghent2.jpg", 51.0550, 3.7200),
                                                    ("sydney.jpg", -33.8568, 151.2153), ("lima.jpg", -12.0464, -77.0428), ("none.jpg", nil, nil)]
        for (name, lat, lon) in places { writeJPEG(folder.appendingPathComponent(name), latitude: lat, longitude: lon) }
        let path = { (name: String) in folder.appendingPathComponent(name).path }

        let read = places.map { PhotoFact.read(path($0.0)) }
        let signsRight = zip(places, read).allSatisfy { place, fact in
            guard let lat = place.1, let lon = place.2 else { return fact?.place == nil }
            return abs((fact?.latitude ?? 0) - lat) < 1e-4 && abs((fact?.longitude ?? 0) - lon) < 1e-4
        }
        check("map reads GPS", signsRight, "N/S and E/W as written; got \(read.map { ($0?.latitude, $0?.longitude) })")
        check("map reads camera", read[0]?.camera == "Sony ILCE-7M4", "make added when the model lacks it; got \(String(describing: read[0]?.camera))")

        // In the background: asking returns at once.
        let catalog = PhotoCatalog.shared
        let started = Date.now
        let album = catalog.newAlbum(named: "Map test", with: places.map { path($0.0) })
        let took = Date.now.timeIntervalSince(started)
        check("map reads in the background", took < 0.1, "under 0.1 s to ask; took \(took)")
        await PhotoFacts.shared.finish()
        let onMap = Set(catalog.photos(in: .map)).intersection(places.map { path($0.0) })
        check("map shows photos with a place", onMap == Set(places.dropLast().map { path($0.0) }), "4 with GPS, not the one without; got \(onMap.count)")
        let key = PhotoCatalog.Source.map.key
        check("map source key", PhotoCatalog.Source(key: key) == .map, key)

        // Pins: grouped when zoomed out, apart when zoomed in.
        let known = PhotoFacts.shared.places(places.map { path($0.0) })
        let world = PhotoCluster.make(known, region: nil)
        let ghent = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.0546, longitude: 3.7187), span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.004))
        let close = PhotoCluster.make(known, region: ghent)
        let ghentPin = world.first { $0.paths.contains(path("ghent.jpg")) }
        check("map groups nearby photos", world.count == 3 && ghentPin?.paths.count == 2, "3 pins, Ghent's with 2; got \(world.map(\.paths.count))")
        // Up close in Ghent: its two photos apart, the far ones (off screen) left out.
        check("map splits zoomed in", close.count == 2 && close.allSatisfy { $0.paths.count == 1 }, "2 pins of 1 up close; got \(close.map(\.paths.count))")
        catalog.deleteAlbum(album.id)
    }

    // MARK: - People

    static func people() async {
        // Looking at a folder of real photos (PLUCK_PEOPLE_DIR): every face against every other, to check the threshold.
        if let dir = ProcessInfo.processInfo.environment["PLUCK_PEOPLE_DIR"],
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            var all: [(String, PhotoFace)] = []
            for name in names.sorted() { for (i, f) in PhotoPeople.faces(in: dir + "/" + name).enumerated() { all.append(("\(name)#\(i)", f)) } }
            for (label, f) in all {
                if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: f.path) as CFURL, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                    let req = VNDetectFaceLandmarksRequest(); try? VNImageRequestHandler(cgImage: image).perform([req])
                    if let obs = req.results?.first(where: { $0.boundingBox == f.box }) {
                        let q = VNDetectFaceCaptureQualityRequest(); q.inputFaceObservations = [obs]; try? VNImageRequestHandler(cgImage: image).perform([q])
                        note("face \(label) yaw \(obs.yaw ?? -9) pitch \(obs.pitch ?? -9) quality \(q.results?.first?.faceCaptureQuality ?? -1) conf \(obs.confidence)")
                    }
                    if let obs = req.results?.first(where: { $0.boundingBox == f.box }), let crop = PhotoPeople.aligned(image, obs),
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/../face-\(label).png") as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, crop, nil); CGImageDestinationFinalize(dest)
                    }
                }
            }
            for i in all.indices { for j in all.indices where j > i && all[i].1.path != all[j].1.path {
                let d = PhotoPeople.distance(all[i].1.print, all[j].1.print)
                if d < 1.3 { note("pair \(all[i].0) \(all[j].0) \(String(format: "%.3f", d))") }
            } }
            note("faces found: \(all.count)")
        }
        let root = (photos as NSString).deletingLastPathComponent
        let portrait = (root as NSString).appendingPathComponent("faces/DSC02868-p6-standard.jpg")
        let sameShotRaw = (root as NSString).appendingPathComponent("raws/DSC02868.ARW")
        let otherShot = (root as NSString).appendingPathComponent("raws/DSC02881.ARW")
        let others = (root as NSString).appendingPathComponent("raws/R6LO7461.CR3")
        guard [portrait, sameShotRaw, otherShot, others].allSatisfy(FileManager.default.fileExists) else {
            return skip("people", "the test portraits aren't next to the photos folder")
        }
        let folder = scratch("people")
        defer { try? FileManager.default.removeItem(at: folder) }

        // The same face, made different: a copy, smaller and recompressed, cropped, darker.
        let copy = folder.appendingPathComponent("copy.jpg").path
        try? FileManager.default.copyItem(atPath: portrait, toPath: copy)
        let picture = CIImage(contentsOf: URL(fileURLWithPath: portrait))!
        let context = CIContext()
        func save(_ image: CIImage, _ name: String, quality: Double = 0.9) -> String {
            let url = folder.appendingPathComponent(name)
            try? context.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
            return url.path
        }
        let smaller = save(picture.transformed(by: CGAffineTransform(scaleX: 0.6, y: 0.6)), "smaller.jpg", quality: 0.5)
        let e = picture.extent
        let cropped = save(picture.cropped(to: CGRect(x: e.minX + e.width * 0.25, y: e.minY, width: e.width * 0.6, height: e.height * 0.9))
            .transformed(by: CGAffineTransform(translationX: -(e.minX + e.width * 0.25), y: -e.minY)), "cropped.jpg")
        let darker = save(picture.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.8]), "darker.jpg")
        let raw = folder.appendingPathComponent("same-shot.ARW").path, shot = folder.appendingPathComponent("other-shot.ARW").path
        let crowd = folder.appendingPathComponent("others.CR3").path
        try? FileManager.default.copyItem(atPath: sameShotRaw, toPath: raw)
        try? FileManager.default.copyItem(atPath: otherShot, toPath: shot)
        try? FileManager.default.copyItem(atPath: others, toPath: crowd)

        // The distances, for the record (and for choosing PhotoPeople.sameBelow).
        let all = [portrait, copy, smaller, cropped, darker, raw, shot, crowd]
        let found = await Task.detached { all.map { PhotoPeople.faces(in: $0) } }.value
        let reference = found[0].first
        check("people finds the face", found[0].count == 1 && found[1...5].allSatisfy { $0.count == 1 }, "one face in the portrait and each variant; got \(found.map(\.count))")
        guard let reference else { return }
        let names = ["copy", "smaller", "cropped", "darker", "same shot (raw)", "other shot"]
        for (index, name) in names.enumerated() {
            let d = found[index + 1].map { PhotoPeople.distance(reference.print, $0.print) }.min() ?? .infinity
            note("people distance to \(name): \(String(format: "%.3f", d))")
        }
        let strangers = found[7].map { PhotoPeople.distance(reference.print, $0.print) }
        note("people distance to other people: \(strangers.map { String(format: "%.3f", $0) })")
        let sameMax = found[1...6].compactMap { $0.map { PhotoPeople.distance(reference.print, $0.print) }.min() }.max() ?? .infinity
        check("people same face matches", sameMax < PhotoPeople.sameBelow, "all variants under \(PhotoPeople.sameBelow); worst \(sameMax)")
        check("people different faces apart", (strangers.min() ?? .infinity) >= PhotoPeople.sameBelow && found[7].count >= 1,
              "other people at \(PhotoPeople.sameBelow) or more; got \(strangers)")

        // The background job: one person for the portrait and its variants, never the others.
        let people = PhotoPeople.shared
        let catalog = PhotoCatalog.shared
        let album = catalog.newAlbum(named: "People test", with: all)
        await people.finish()
        let personOf = { (path: String) in people.people(in: path) }
        let her = personOf(portrait).first
        let together = all.prefix(7).allSatisfy { personOf($0) == personOf(portrait) } && her != nil
        check("people groups the same person", together, "the portrait, its variants and the other shot as one; got \(all.prefix(7).map { personOf($0).count })")
        check("people keeps others apart", her.map { !personOf(crowd).contains($0) } ?? false, "nobody in the crowd is her")
        let crowdFaces = people.faces.filter { $0.path == crowd }
        check("people never twice in one photo", Set(crowdFaces.compactMap(\.person)).count == crowdFaces.compactMap(\.person).count, "two faces in one photo, two people")
        guard let her else { return }

        // Naming, Find, smart albums, removing a face, merging.
        people.rename(her, to: "Sam Example")
        check("people find by name", people.photos(named: ["sam"]).isSuperset(of: [portrait, shot]), "Find 'sam' gives her photos")
        let smart = SmartAlbum(name: "Sam", rules: [SmartRule(field: .person, text: her.uuidString)])
        catalog.save(smart: smart)
        check("people smart album", Set(catalog.photos(in: .smart(smart.id))).isSuperset(of: [portrait, shot]) && !catalog.photos(in: .smart(smart.id)).contains(crowd),
              "her photos, not the crowd")
        catalog.deleteSmartAlbum(smart.id)
        check("people source", catalog.photos(in: .person(her)).contains(portrait), "her photos as a source")
        if let wrong = people.faces.first(where: { $0.path == darker }) {
            people.removeFace(wrong.id)
            check("people remove a face", !people.people(in: darker).contains(her) && people.faces.first { $0.id == wrong.id }?.removed == true,
                  "the darker copy is off her, and stays off")
        }
        if let face = people.faces.first(where: { $0.path == cropped }), let split = people.splitOff(face.id) {
            let apart = people.people(in: cropped) == [split]
            people.merge(split, into: her)
            check("people merge", apart && people.person(split) == nil && people.people(in: cropped) == [her] && people.person(her)?.name == "Sam Example",
                  "the other person's faces are hers, her name kept")
        } else {
            check("people merge", false, "no face to split off")
        }
        catalog.deleteAlbum(album.id)
    }
}
