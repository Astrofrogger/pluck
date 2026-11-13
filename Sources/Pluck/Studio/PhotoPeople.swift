import CoreImage
import Foundation
import SwiftUI
import ImageIO
import Vision
import CoreML

/// One face found in a photo, with what it looks like as numbers (to find the same face again).
struct PhotoFace: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The file (copies share their file's faces).
    var path: String
    /// Where, in Vision's terms: 0…1, from the bottom left.
    var box: CGRect
    /// The feature print of the face, cut out and turned so the eyes are level (see PhotoPeople).
    var print: [Float]
    var person: UUID?
    /// Taken off a person by hand: never put in one again by itself.
    var removed: Bool?

    private enum CodingKeys: String, CodingKey { case id, path, box, print, person, removed }

    init(path: String, box: CGRect, print: [Float]) {
        self.path = path
        self.box = box
        self.print = print
    }

    // The print is kept as raw bytes (a tenth of the size of a list of numbers in JSON).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        box = try c.decode(CGRect.self, forKey: .box)
        let data = try c.decode(Data.self, forKey: .print)
        print = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        person = try c.decodeIfPresent(UUID.self, forKey: .person)
        removed = try c.decodeIfPresent(Bool.self, forKey: .removed)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(box, forKey: .box)
        try c.encode(print.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .print)
        try c.encodeIfPresent(person, forKey: .person)
        try c.encodeIfPresent(removed, forKey: .removed)
    }
}

/// Someone who turns up in several photos. Unnamed until named.
struct PhotoPerson: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String?
}

/// The same person across the library, found on this Mac.
///
/// Vision finds the faces; a face-recognition model tells who they are: SFace (OpenCV's model zoo, Apache-2.0, converted to
/// Core ML, in the app's Resources › Models). Each face is cut out at 112 px with the eyes where the model was trained to see
/// them (from Vision's landmarks) and turned into 128 numbers, scaled to length 1. Two faces closer than `sameBelow` are taken
/// to be the same person (OpenCV's own threshold for this model: a cosine of 0.363); a new face joins the person of the
/// nearest face that close (never a person already in that photo), or starts a new person with it.
///
/// (Before 2026-11-13 Vision's general image feature print was used: it put two different people together, the owner found.
/// Its prints don't compare with these, so People.json of that time is read as empty and the photos looked at again.)
@MainActor
@Observable
final class PhotoPeople {
    static let shared = PhotoPeople()

    /// See above: the distance under which two faces are taken to be the same person.
    nonisolated static let sameBelow: Float = 1.128
    /// Faces narrower than this (in pixels, on the 1600 px picture looked at) are too small to tell.
    nonisolated static let smallestFace: CGFloat = 40

    private(set) var faces: [PhotoFace] = []
    private(set) var people: [PhotoPerson] = []
    /// The files looked at already.
    @ObservationIgnored private var scanned: Set<String> = []
    /// Goes up with each change (smart albums use it to know when to look again).
    @ObservationIgnored private(set) var revision = 0
    private(set) var working = false
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var saveScheduled = false
    private static let version = 2

    nonisolated private static var file: URL {
        // Tests keep theirs next to their own catalogue.
        if let test = UserDefaults.standard.string(forKey: "PluckScreenshotCatalog") {
            return URL(fileURLWithPath: test).deletingLastPathComponent().appendingPathComponent("people.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Photos/People.json")
    }

    private struct Saved: Codable {
        var version: Int
        var faces: [PhotoFace]
        var people: [PhotoPerson]
        var scanned: [String]
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.version == Self.version {
            faces = saved.faces
            people = saved.people
            scanned = Set(saved.scanned)
        }
    }

    // MARK: - Looking

    /// Looks for faces in these files (the ones not looked at yet), one by one, in the background,
    /// at low priority and never while a photo is being edited. Saved as it goes.
    func enqueue(_ paths: [String]) {
        let new = PhotoCatalog.files(of: paths).filter { !scanned.contains($0) && !waiting.contains($0) }
        guard !new.isEmpty else { return }
        waiting.append(contentsOf: new)
        guard !working else { return }
        working = true
        Task {
            while !waiting.isEmpty {
                // Editing comes first: wait while the Photo page is on Edit or Compare.
                while Self.editing { try? await Task.sleep(for: .seconds(2)) }
                let path = waiting.removeFirst()
                let found = await Task.detached(priority: .background) { Self.faces(in: path) }.value
                add(found, from: path)
            }
            working = false
        }
    }

    /// Waits until everything asked for has been looked at (tests).
    func finish() async {
        while working || !waiting.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
    }

    nonisolated private static var editing: Bool {
        ScreenshotMode.scene != "phototest" && ["edit", "compare"].contains(UserDefaults.standard.string(forKey: "photoView") ?? "")
    }

    /// A file's faces, placed with the people already known.
    func add(_ found: [PhotoFace], from path: String) {
        scanned.insert(path)
        for var face in found {
            face.person = match(for: face)
            faces.append(face)
        }
        changed()
    }

    /// The person a new face belongs to: the one of the nearest face close enough that isn't in the
    /// same photo already. A face close enough that has no person yet starts one with it.
    private func match(for face: PhotoFace) -> UUID? {
        let taken = Set(faces.filter { $0.path == face.path }.compactMap(\.person))
        let near = faces.indices
            .filter { faces[$0].path != face.path && faces[$0].removed != true }
            .map { ($0, Self.distance(face.print, faces[$0].print)) }
            .filter { $0.1 < Self.sameBelow }
            .sorted { $0.1 < $1.1 }
        for (index, _) in near {
            if let person = faces[index].person {
                if !taken.contains(person) { return person }
            } else {
                let person = PhotoPerson()
                people.append(person)
                faces[index].person = person.id
                return person.id
            }
        }
        return nil
    }

    nonisolated static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .infinity }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }

    nonisolated private static let context = CIContext()

    /// The faces in a file big enough to tell, each with its feature print.
    nonisolated static func faces(in path: String) -> [PhotoFace] {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return [] }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        return faces(in: image, path: path)
    }

    nonisolated static func faces(in image: CGImage, path: String) -> [PhotoFace] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { face in
            // (A face turned side-on can't be told: Vision gives it a yaw of 90°. One such matched a different person.)
            guard abs(face.yaw?.doubleValue ?? 0) < 1.2 else { return nil }
            guard face.boundingBox.width * size.width >= smallestFace, let crop = aligned(image, face),
                  let print = facePrint(crop) else { return nil }
            return PhotoFace(path: path, box: face.boundingBox, print: print)
        }
    }

    /// The face cut out at 112 × 112, turned so the eyes are level, the eyes where SFace was trained to see them (the usual
    /// face-recognition template: 38.3 and 73.5 px across, 51.6 px down).
    nonisolated static func aligned(_ image: CGImage, _ face: VNFaceObservation, side: CGFloat = 112) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        func centre(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.pointsInImage(imageSize: size), !points.isEmpty else { return nil }
            return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        }
        let box = face.boundingBox
        // Without landmarks: where eyes usually are in Vision's box.
        let a = centre(face.landmarks?.leftPupil) ?? centre(face.landmarks?.leftEye)
            ?? CGPoint(x: (box.minX + box.width * 0.3) * size.width, y: (box.minY + box.height * 0.62) * size.height)
        let b = centre(face.landmarks?.rightPupil) ?? centre(face.landmarks?.rightEye)
            ?? CGPoint(x: (box.minX + box.width * 0.7) * size.width, y: (box.minY + box.height * 0.62) * size.height)
        let (left, right) = a.x < b.x ? (a, b) : (b, a)
        let apart = hypot(right.x - left.x, right.y - left.y)
        guard apart > 2 else { return nil }
        let angle = atan2(right.y - left.y, right.x - left.x)
        let k = side / 112, scale = 35.24 * k / apart
        let transform = CGAffineTransform(translationX: -(left.x + right.x) / 2, y: -(left.y + right.y) / 2)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: 55.91 * k, y: side - 51.6 * k))
        let frame = CGRect(x: 0, y: 0, width: side, height: side)
        let cut = CIImage(cgImage: image).clampedToExtent().transformed(by: transform).cropped(to: frame)
        return context.createCGImage(cut, from: frame)
    }

    nonisolated(unsafe) private static var model: MLModel?
    nonisolated private static let modelLock = NSLock()

    /// SFace's model in the app (nil without it: People then finds no one).
    nonisolated static var modelURL: URL? { Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc", subdirectory: "Models") }

    /// The face (112 × 112, from `aligned`) as SFace's 128 numbers, scaled to length 1.
    nonisolated static func facePrint(_ image: CGImage) -> [Float]? {
        modelLock.withLock {
            if model == nil, let url = modelURL { model = try? MLModel(contentsOf: url) }
            guard let model, let input = try? MLFeatureValue(cgImage: image, pixelsWide: 112, pixelsHigh: 112, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
                  let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input])),
                  let array = out.featureValue(for: "print")?.multiArrayValue else { return nil }
            var v = (0..<array.count).map { Float(truncating: array[$0]) }
            let length = v.map { $0 * $0 }.reduce(0, +).squareRoot()
            guard length > 0 else { return nil }
            for i in v.indices { v[i] /= length }
            return v
        }
    }

    // MARK: - People

    /// The people to show: named, or seen in two photos or more; the most seen first.
    var shown: [PhotoPerson] {
        let counts = Dictionary(grouping: faces.filter { $0.person != nil }, by: { $0.person! }).mapValues(\.count)
        return people.filter { $0.name != nil || (counts[$0.id] ?? 0) >= 2 }
            .sorted { (counts[$0.id] ?? 0, $1.name ?? "") > (counts[$1.id] ?? 0, $0.name ?? "") }
    }

    func person(_ id: UUID) -> PhotoPerson? { people.first { $0.id == id } }

    /// The name to show ("Person 3" until named).
    func title(_ person: PhotoPerson) -> String {
        if let name = person.name { return name }
        let number = (people.firstIndex(of: person) ?? 0) + 1
        return String(localized: "Person \(number)")
    }

    func faces(of person: UUID) -> [PhotoFace] { faces.filter { $0.person == person } }

    /// The files a person is in, each once.
    func photos(of person: UUID) -> [String] {
        var seen: Set<String> = []
        return faces.filter { $0.person == person && seen.insert($0.path).inserted }.map(\.path)
    }

    /// The people in a file (copies: their file's).
    func people(in path: String) -> Set<UUID> {
        let file = PhotoCatalog.file(of: path)
        return Set(faces.filter { $0.path == file }.compactMap(\.person))
    }

    /// The files of everyone whose name holds all these words (Find).
    func photos(named words: [String]) -> Set<String> {
        let words = words.map(PhotoIndex.normalized)
        let ids = people.filter { person in
            guard let name = person.name.map(PhotoIndex.normalized) else { return false }
            return words.allSatisfy { name.contains($0) }
        }.map(\.id)
        return Set(ids.flatMap(photos(of:)))
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        people[index].name = name.isEmpty ? nil : name
        changed()
    }

    /// Puts `from`'s faces with `into`'s; `into` keeps its name (or takes `from`'s if it had none).
    func merge(_ from: UUID, into: UUID) {
        guard from != into, let source = person(from), let index = people.firstIndex(where: { $0.id == into }) else { return }
        for i in faces.indices where faces[i].person == from { faces[i].person = into }
        if people[index].name == nil { people[index].name = source.name }
        people.removeAll { $0.id == from }
        changed()
    }

    /// A face that isn't that person: taken off, and never put with anyone again by itself.
    func removeFace(_ id: UUID) {
        guard let index = faces.firstIndex(where: { $0.id == id }), let person = faces[index].person else { return }
        faces[index].person = nil
        faces[index].removed = true
        if !faces.contains(where: { $0.person == person }), self.person(person)?.name == nil { people.removeAll { $0.id == person } }
        changed()
    }

    /// Tests: one face moved to a new person of its own (as if it had been told apart); that person.
    func splitOff(_ face: UUID) -> UUID? {
        guard let index = faces.firstIndex(where: { $0.id == face }) else { return nil }
        let person = PhotoPerson()
        people.append(person)
        faces[index].person = person.id
        changed()
        return person.id
    }

    // MARK: - Saving

    private func changed() {
        revision += 1
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saveScheduled = false
            let saved = Saved(version: Self.version, faces: faces, people: people, scanned: Array(scanned))
            await Task.detached(priority: .background) {
                try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
            }.value
        }
    }
}

// MARK: - Views

/// A face, cut from its photo with a little room, round.
struct PersonFaceImage: View {
    let face: PhotoFace
    var size: CGFloat = 20
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() } else { Color.gray.opacity(0.3) }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: face.id) { image = await PersonFaceImage.load(face) }
    }

    @MainActor private static var cache: [UUID: CGImage] = [:]

    @MainActor static func load(_ face: PhotoFace) async -> CGImage? {
        if let known = cache[face.id] { return known }
        let made = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: face.path) as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let w = CGFloat(picture.width), h = CGFloat(picture.height), box = face.box
            let side = max(box.width * w, box.height * h) * 1.4
            // Vision's box is from the bottom left; the picture's rows from the top.
            let rect = CGRect(x: box.midX * w - side / 2, y: (1 - box.midY) * h - side / 2, width: side, height: side)
            return picture.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral)
        }.value
        if let made { cache[face.id] = made }
        return made
    }
}

/// The People section of the Photo page's sidebar: each person with a face, named or not. Click
/// shows their photos; the menu names them or puts two together (or drag one onto another).
struct PeopleSidebarSection: View {
    let selected: UUID?
    let open: (UUID) -> Void
    @State private var people = PhotoPeople.shared
    @State private var renaming: UUID?
    @State private var name = ""

    var body: some View {
        let shown = people.shown
        if !shown.isEmpty || people.working {
            SidebarGap()
            SidebarSection(title: Text("People"), fold: "photo-people", count: shown.count, pinned: true) {
                ForEach(shown) { person in
                    personRow(person, others: shown.filter { $0.id != person.id })
                }
                if people.working {
                    Text("Finding people…").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                        .padding(.leading, Design.Sidebar.rowPadding)
                        .frame(height: Design.Sidebar.rowHeight)
                }
            }
            .alert("Name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("OK") { if let id = renaming { people.rename(id, to: name) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func personRow(_ person: PhotoPerson, others: [PhotoPerson]) -> some View {
        let count = people.photos(of: person.id).count
        // No symbol: the face goes in its place.
        return SidebarRow(symbol: "circle.fill", title: Text(people.title(person)), detail: Text(verbatim: "\(count)").foregroundStyle(.secondary),
                          selected: selected == person.id) {
            EmptyView()
        }
        .overlay(alignment: .leading) {
            if let face = people.faces(of: person.id).first {
                PersonFaceImage(face: face, size: 18)
                    .padding(.leading, Design.Sidebar.rowPadding - 1)
                    .allowsHitTesting(false)
            }
        }
        .onTapGesture { open(person.id) }
        .contextMenu {
            Button("Name…") { name = person.name ?? ""; renaming = person.id }
            if !others.isEmpty {
                Menu("Merge Into") {
                    ForEach(others) { other in
                        Button(people.title(other)) {
                            people.merge(person.id, into: other.id)
                            if selected == person.id { open(other.id) }
                        }
                    }
                }
            }
        }
        .draggable(person.id.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init(uuidString:)) where id != person.id { people.merge(id, into: person.id) }
            return true
        }
    }
}

/// A person's faces above their photos, to take off one that isn't them.
struct PersonFacesStrip: View {
    let person: UUID
    @State private var people = PhotoPeople.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(people.faces(of: person)) { face in
                    PersonFaceImage(face: face, size: 48)
                        .contextMenu {
                            Button("Not This Person", role: .destructive) { people.removeFace(face.id) }
                        }
                        .help("Right-click if this isn’t them")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(height: 64)
    }
}
