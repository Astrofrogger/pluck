import Foundation

/// Which camera a card is from, by what the camera writes on it: its brand and model, and its ID
/// or serial number where it writes one (so a project knows the card's operator next time).
struct CameraCard: Hashable, Sendable {
    var brand: String
    var model: String?
    /// The camera's ID or serial, with its brand ("Sony 1234567"); nil when the card doesn't say.
    var key: String?
    /// The camera letter, where the camera writes one (RED, Blackmagic).
    var letter: String?

    /// "Sony ILCE-7SM3", or the brand alone.
    var name: String {
        guard let model, !model.isEmpty else { return brand }
        return model.lowercased().hasPrefix(brand.lowercased()) ? model : brand + " " + model
    }

    static func read(_ volume: URL) -> CameraCard {
        let files = Listing(volume)
        return red(files) ?? sony(files) ?? blackmagic(files) ?? canon(files) ?? goPro(files) ?? insta360(files) ?? dji(files)
            ?? CameraCard(brand: "Camera")
    }

    // MARK: - Brands

    /// RED: clips named A001_C001_0921K7 (the camera letter, then the card's reel); the letter is
    /// what RED calls the camera's ID.
    private static func red(_ files: Listing) -> CameraCard? {
        guard let clip = files.first(where: { ["rdc", "r3d"].contains($0.pathExtension.lowercased()) }) else { return nil }
        let name = clip.lastPathComponent.uppercased()
        guard let first = name.first, first.isLetter, name.dropFirst().prefix(3).allSatisfy(\.isNumber) else {
            return CameraCard(brand: "RED")
        }
        return CameraCard(brand: "RED", key: "RED \(first)", letter: String(first))
    }

    /// Sony XAVC: each clip's M01.XML names the camera (`<Device modelName serialNo>`).
    private static func sony(_ files: Listing) -> CameraCard? {
        let isSony = files.contains { ["m4root", "xdroot"].contains($0.lastPathComponent.lowercased()) }
        let xml = files.first { $0.lastPathComponent.uppercased().hasSuffix("M01.XML") }
        guard isSony || xml != nil else { return nil }
        let device = xml.flatMap(DeviceXML.read)
        return CameraCard(brand: "Sony", model: device?.model, key: device?.serial.map { "Sony \($0)" })
    }

    /// Blackmagic RAW: the camera's type, ID and letter in the clip's metadata (read by pluck-raw).
    private static func blackmagic(_ files: Listing) -> CameraCard? {
        guard let clip = files.first(where: { $0.pathExtension.lowercased() == "braw" }) else { return nil }
        var meta: [String: String] = [:]
        if let source = try? RawHelperSource(url: clip) {
            meta = source.info.meta
            source.close()
        }
        func value(_ keys: String...) -> String? { keys.lazy.compactMap { meta[$0] }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        let id = value("camera_id", "serial_number", "camera_serial_number")
        return CameraCard(brand: "Blackmagic", model: value("camera_type", "camera_model"), key: id.map { "Blackmagic \($0)" },
                          letter: value("camera_number", "camera_index").map { String($0.prefix(1)).uppercased() })
    }

    /// Canon: an XML beside the clips (Cinema EOS), or the camera's EXIF inside a CRM.
    private static func canon(_ files: Listing) -> CameraCard? {
        let crm = files.first { $0.pathExtension.lowercased() == "crm" }
        let isCanon = crm != nil || files.contains { $0.lastPathComponent.uppercased().hasSuffix("CANON") }
            || files.contains { $0.lastPathComponent.uppercased().hasPrefix("CLIPS0") }
        guard isCanon else { return nil }
        if let xml = files.first(where: { $0.pathExtension.lowercased() == "xml" }), let device = DeviceXML.read(xml), device.model != nil {
            return CameraCard(brand: "Canon", model: device.model, key: device.serial.map { "Canon \($0)" })
        }
        if let crm, let exif = CRM.read(crm) {
            return CameraCard(brand: "Canon", model: exif.model, key: exif.serial.map { "Canon \($0)" })
        }
        return CameraCard(brand: "Canon")
    }

    /// GoPro: MISC/version.txt names the camera and its serial; else the serial in a clip's GPMF.
    private static func goPro(_ files: Listing) -> CameraCard? {
        let version = files.first { $0.lastPathComponent.lowercased() == "version.txt" && $0.deletingLastPathComponent().lastPathComponent.uppercased() == "MISC" }
        let clip = files.first { $0.deletingLastPathComponent().lastPathComponent.uppercased().hasSuffix("GOPRO") && $0.pathExtension.lowercased() == "mp4" }
        guard version != nil || clip != nil else { return nil }
        if let version, let text = try? String(contentsOf: version, encoding: .utf8) {
            func field(_ name: String) -> String? {
                guard let range = text.range(of: "\"\(name)\"\\s*:\\s*\"([^\"]*)\"", options: .regularExpression) else { return nil }
                let pair = text[range]
                guard let colon = pair.firstIndex(of: ":") else { return nil }
                let value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return value.isEmpty ? nil : value
            }
            if let serial = field("camera serial number") {
                return CameraCard(brand: "GoPro", model: field("camera type"), key: "GoPro \(serial)")
            }
        }
        if let clip, let data = MP4.box(["moov", "udta"], in: clip) {
            let serial = GPMF.string("CASN", in: data) ?? MP4.child("CAME", in: data).map { $0.map { String(format: "%02x", $0) }.joined() }
            return CameraCard(brand: "GoPro", model: GPMF.string("MINF", in: data), key: serial.map { "GoPro \($0)" })
        }
        return CameraCard(brand: "GoPro")
    }

    /// Insta360: the serial and camera type in the record at the end of each INSV.
    private static func insta360(_ files: Listing) -> CameraCard? {
        guard let clip = files.first(where: { $0.pathExtension.lowercased() == "insv" }) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: clip) else { return CameraCard(brand: "Insta360") }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 1 << 20 ? end - (1 << 20) : 0)
        let tail = [UInt8]((try? handle.readToEnd()) ?? Data())
        // camera_type ("Insta360 X3"), field 2, right after serial_number, field 1.
        let mark = Array("Insta360".utf8)
        var at = 2
        while at + mark.count <= tail.count {
            if matches(mark, in: tail, at: at), tail[at - 2] == 0x12 {
                let length = Int(tail[at - 1])
                let model = at + length <= tail.count ? String(decoding: tail[at..<(at + length)], as: UTF8.self) : nil
                var serial: String?
                let field = at - 2
                for start in stride(from: field - 3, through: max(field - 40, 0), by: -1)
                where tail[start] == 0x0A && start + 2 + Int(tail[start + 1]) == field {
                    let text = String(decoding: tail[(start + 2)..<field], as: UTF8.self)
                    if !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber }) { serial = text }
                    break
                }
                return CameraCard(brand: "Insta360", model: model, key: serial.map { "Insta360 \($0)" })
            }
            at += 1
        }
        return CameraCard(brand: "Insta360")
    }

    /// DJI: DJI_ clips, the model in the MP4's user data where it's written.
    private static func dji(_ files: Listing) -> CameraCard? {
        guard let clip = files.first(where: { $0.lastPathComponent.uppercased().hasPrefix("DJI_") && ["mp4", "mov"].contains($0.pathExtension.lowercased()) })
        else { return nil }
        let data = MP4.box(["moov", "udta"], in: clip) ?? Data()
        let model = MP4.text("\u{A9}mdl", in: data) ?? MP4.text("\u{A9}mod", in: data)
        let serial = MP4.text("\u{A9}sn ", in: data)
        return CameraCard(brand: "DJI", model: model, key: serial.map { "DJI \($0)" })
    }
}

// MARK: - Reading a card

/// What's on a card, a few folders deep (enough for every camera's own folders), not every file
/// of a full card.
private struct Listing: Sequence {
    let urls: [URL]

    init(_ volume: URL) {
        var found: [URL] = []
        func walk(_ folder: URL, depth: Int) {
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                       options: [.skipsHiddenFiles])) ?? []
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where found.count < 4000 {
                found.append(item)
                let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                // (A RED clip is a folder of R3Ds; its name is enough.)
                if isFolder, depth < 4, item.pathExtension.lowercased() != "rdc" { walk(item, depth: depth + 1) }
            }
        }
        walk(volume, depth: 1)
        urls = found
    }

    func makeIterator() -> IndexingIterator<[URL]> { urls.makeIterator() }
}

/// The camera named in an XML a camera writes: Sony's `<Device manufacturer modelName serialNo>`,
/// or elements such as `<ModelName>` and `<SerialNumber>`.
private final class DeviceXML: NSObject, XMLParserDelegate {
    private(set) var model: String?
    private(set) var serial: String?
    private var text = ""

    static func read(_ url: URL) -> (model: String?, serial: String?)? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let reader = DeviceXML()
        parser.delegate = reader
        parser.parse()
        return reader.model == nil && reader.serial == nil ? nil : (reader.model, reader.serial)
    }

    private static let models: Set<String> = ["modelname", "model"]
    private static let serials: Set<String> = ["serialno", "serialnumber", "serial"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        for (key, value) in attributes where !value.isEmpty {
            if Self.models.contains(key.lowercased()), model == nil { model = value }
            if Self.serials.contains(key.lowercased()), serial == nil { serial = value }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard !value.isEmpty else { return }
        if Self.models.contains(name.lowercased()), model == nil { model = value }
        if Self.serials.contains(name.lowercased()), serial == nil { serial = value }
    }
}

/// MP4 and MOV boxes, found with seeks (a clip's media isn't read).
enum MP4 {
    /// A box's contents, by the path of box types to it ("moov", "udta"); at most 4 MB.
    static func box(_ path: [String], in url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var start: UInt64 = 0, end = size
        for (depth, type) in path.enumerated() {
            guard let found = find(type, in: handle, from: start, to: end) else { return nil }
            start = found.start
            end = found.end
            if depth == path.count - 1 {
                try? handle.seek(toOffset: start)
                return try? handle.read(upToCount: Int(min(end - start, 4 << 20)))
            }
        }
        return nil
    }

    private static func find(_ type: String, in handle: FileHandle, from start: UInt64, to end: UInt64) -> (start: UInt64, end: UInt64)? {
        var at = start
        while at + 8 <= end {
            try? handle.seek(toOffset: at)
            guard let header = try? handle.read(upToCount: 16), header.count >= 8 else { return nil }
            let bytes = [UInt8](header)
            var size = UInt64(bytes[0]) << 24 | UInt64(bytes[1]) << 16 | UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            var body = at + 8
            if size == 1, bytes.count >= 16 {
                size = bytes[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
                body = at + 16
            } else if size == 0 {
                size = end - at
            }
            guard size >= body - at else { return nil }
            if matches(typeBytes(type), in: bytes, at: 4) { return (body, min(at + size, end)) }
            at += size
        }
        return nil
    }

    /// A box straight inside these bytes (a box's contents), by its type.
    static func child(_ type: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var at = 0
        while at + 8 <= bytes.count {
            let size = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard size >= 8, at + size <= bytes.count else { return nil }
            if matches(typeBytes(type), in: bytes, at: at + 4) { return Data(bytes[(at + 8)..<(at + size)]) }
            at += size
        }
        return nil
    }

    /// A QuickTime user-data text (©mdl and the like: its length, its language, the text).
    static func text(_ type: String, in data: Data) -> String? {
        guard let box = child(type, in: data), box.count > 4 else { return nil }
        let bytes = [UInt8](box)
        let length = min(Int(bytes[0]) << 8 | Int(bytes[1]), bytes.count - 4)
        let text = String(decoding: bytes[4..<(4 + length)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text
    }
}

/// Whether these bytes are at this place (no copies made while searching).
private func matches(_ mark: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
    guard index >= 0, index + mark.count <= bytes.count else { return false }
    for n in mark.indices where bytes[index + n] != mark[n] { return false }
    return true
}

/// A box type as its bytes ("©" is one byte, 0xA9).
private func typeBytes(_ type: String) -> [UInt8] { type.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

/// GoPro's metadata (key, type, size, count, then the value), as in a clip's GPMF.
private enum GPMF {
    /// A text value (CASN, the serial; MINF, the model).
    static func string(_ key: String, in data: Data) -> String? {
        let bytes = [UInt8](data), mark = Array(key.utf8)
        var at = 0
        while at + 8 <= bytes.count {
            if matches(mark, in: bytes, at: at), bytes[at + 4] == UInt8(ascii: "c") {
                let length = Int(bytes[at + 5]) * (Int(bytes[at + 6]) << 8 | Int(bytes[at + 7]))
                guard at + 8 + length <= bytes.count else { return nil }
                let text = String(decoding: bytes[(at + 8)..<(at + 8 + length)], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                return text.isEmpty ? nil : text
            }
            at += 1
        }
        return nil
    }
}

/// The camera's model and serial in a Canon CRM (its EXIF, in the CMT1 and CMT2 boxes).
private enum CRM {
    static func read(_ url: URL) -> (model: String?, serial: String?)? {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 512 << 10) else { return nil }
        try? handle.close()
        let bytes = [UInt8](head)
        let model = tiff(after: "CMT1", in: bytes)[0x0110]
        let serial = tiff(after: "CMT2", in: bytes)[0xA431]
        return model == nil && serial == nil ? nil : (model, serial)
    }

    /// The text tags of the first IFD of the TIFF in a box.
    private static func tiff(after type: String, in bytes: [UInt8]) -> [UInt16: String] {
        let mark = Array(type.utf8)
        guard let at = (0..<max(bytes.count - 12, 0)).first(where: { matches(mark, in: bytes, at: $0) }) else { return [:] }
        let tiff = Array(bytes[(at + 4)...])
        guard tiff.count > 8 else { return [:] }
        let little = tiff[0] == 0x49
        func u16(_ i: Int) -> Int { i + 1 < tiff.count ? (little ? Int(tiff[i]) | Int(tiff[i + 1]) << 8 : Int(tiff[i]) << 8 | Int(tiff[i + 1])) : 0 }
        func u32(_ i: Int) -> Int { u16(little ? i + 2 : i) << 16 | u16(little ? i : i + 2) }
        var found: [UInt16: String] = [:]
        let ifd = u32(4), count = u16(ifd)
        for n in 0..<min(count, 200) {
            let entry = ifd + 2 + n * 12
            guard entry + 12 <= tiff.count, u16(entry + 2) == 2 else { continue }
            let length = u32(entry + 4)
            let offset = length <= 4 ? entry + 8 : u32(entry + 8)
            guard length > 0, offset + length <= tiff.count else { continue }
            let text = String(decoding: tiff[offset..<(offset + length)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !text.isEmpty { found[UInt16(u16(entry))] = text }
        }
        return found
    }
}
