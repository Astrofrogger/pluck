import CoreLocation
import Foundation
import ImageIO

/// What a photo's file says about where and how it was taken: the camera, the lens, when, and
/// where (GPS). Only the file's header is read (no picture), so it's quick.
struct PhotoFact: Codable, Hashable {
    var camera: String?
    var lens: String?
    var taken: Date?
    var latitude: Double?
    var longitude: Double?

    var place: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Reads one file's header (copies: their file's).
    nonisolated static func read(_ path: String) -> PhotoFact? {
        let url = URL(fileURLWithPath: PhotoCatalog.file(of: path))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var fact = PhotoFact()
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Most cameras repeat the make in the model ("Canon EOS R5"); some don't ("ILCE-7M4").
        let camera = model.localizedCaseInsensitiveContains(make) || make.isEmpty ? model : make + " " + model
        fact.camera = camera.isEmpty ? nil : camera
        let lens = (exif?[kCGImagePropertyExifLensModel] as? String)
            ?? ((properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any])?[kCGImagePropertyExifAuxLensModel] as? String)
        fact.lens = lens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if exif?[kCGImagePropertyExifDateTimeOriginal] != nil { fact.taken = PhotoChecks.taken(url, properties: properties) }
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
           !(lat == 0 && lon == 0) {
            fact.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S" ? -lat : lat
            fact.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W" ? -lon : lon
        }
        return fact
    }
}

/// The facts of every photo Pluck knows, read in the background once per file and kept on disk
/// (like the checks), so the Map and smart albums never wait on a drive.
@MainActor
@Observable
final class PhotoFacts {
    static let shared = PhotoFacts()
    private(set) var facts: [String: PhotoFact] = [:]
    /// Goes up with each fact found (smart albums use it to know when to look again).
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored private var saveScheduled = false
    private static let version = 1

    nonisolated private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Photo Facts.json")
    }

    private struct Saved: Codable {
        var version: Int
        var facts: [String: PhotoFact]
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.version {
            facts = saved.facts
        }
    }

    /// A file's facts (copies: their file's).
    func fact(_ path: String) -> PhotoFact? { facts[PhotoCatalog.file(of: path)] }

    /// Reads these files (the ones not read yet), one after the other, in the background.
    func enqueue(_ paths: [String]) {
        let new = PhotoCatalog.files(of: paths).filter { facts[$0] == nil && !waiting.contains($0) }
        guard !new.isEmpty else { return }
        waiting.append(contentsOf: new)
        guard !running else { return }
        running = true
        Task {
            while !waiting.isEmpty {
                let path = waiting.removeFirst()
                // A file that can't be read gets an empty fact: not read again every launch.
                let found = await Task.detached(priority: .utility) { PhotoFact.read(path) }.value ?? PhotoFact()
                facts[path] = found
                revision += 1
                scheduleSave()
            }
            running = false
        }
    }

    /// Waits until everything asked for has been read (tests).
    func finish() async {
        while running || !waiting.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The photos (of these) with a place, and where.
    func places(_ paths: [String]) -> [(path: String, place: CLLocationCoordinate2D)] {
        paths.compactMap { path in fact(path)?.place.map { (path, $0) } }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            saveScheduled = false
            let saved = Saved(version: Self.version, facts: facts)
            await Task.detached(priority: .background) {
                try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
            }.value
        }
    }
}
