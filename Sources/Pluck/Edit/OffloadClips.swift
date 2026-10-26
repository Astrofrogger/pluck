import AVFoundation
import AppKit
import QuickLookThumbnailing

/// What's known about one clip of an offloaded card. Whatever can't be read stays nil.
struct ClipDetails: Codable, Hashable, Sendable {
    /// Where the clip is on the card (the copy's path when read on its own).
    var path: String
    var duration: Double?
    var fps: Double?
    var width: Int?
    var height: Int?
    var codec: String?
    var camera: String?
    var lens: String?
    var iso: Double?
    /// In seconds (0.02 for 1/50).
    var shutter: Double?
    /// In kelvin.
    var whiteBalance: Double?
    var lut: String?

    init(path: String) { self.path = path }
}

/// Reads a clip's details and picture from a copy: AVFoundation first, then the camera's XML
/// beside it (Sony, Canon), and pluck-raw for RED and Blackmagic RAW. It always answers: a clip
/// it can't read gives what's known (its path), never an error.
enum OffloadClips {
    static let rawKinds: Set<String> = ["r3d", "braw", "crm"]
    /// What's worked out for a card: its video files (not the camera's proxies).
    static let videoKinds: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "mts", "m2ts", "r3d", "braw", "crm"]

    static func read(_ file: URL) async -> ClipDetails {
        var details = ClipDetails(path: file.path)
        if rawKinds.contains(file.pathExtension.lowercased()) {
            readRaw(file, into: &details)
        } else {
            await readMovie(file, into: &details)
        }
        readSidecar(file, into: &details)
        return details
    }

    /// A picture from the clip, at most `size` points on its long side (nil when there isn't one).
    static func thumbnail(_ file: URL, size: CGFloat) async -> CGImage? {
        if rawKinds.contains(file.pathExtension.lowercased()) { return rawPicture(file, size: size) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        if let picture = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image { return picture }
        if let picture = try? await generator.image(at: .zero).image { return picture }
        // Anything else the system can draw (a photo, a movie AVFoundation can't open).
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    // MARK: - Movies

    private static func readMovie(_ file: URL, into details: inout ClipDetails) async {
        let asset = AVURLAsset(url: file)
        if let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 { details.duration = time.seconds }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize), size.width > 0 {
                details.width = Int(size.width.rounded())
                details.height = Int(size.height.rounded())
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 { details.fps = Double(rate) }
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                details.codec = codecName(CMFormatDescriptionGetMediaSubType(format))
            }
        }
        if let items = try? await asset.load(.commonMetadata) {
            let model = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierModel).first
            let make = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierMake).first
            let name = (try? await model?.load(.stringValue)) ?? nil
            let brand = (try? await make?.load(.stringValue)) ?? nil
            details.camera = [brand, name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty
        }
        // QuickTime's own camera model, where it's in the file's user data.
        if details.camera == nil, let user = MP4.box(["moov", "udta"], in: file) {
            details.camera = MP4.text("©mod", in: user) ?? MP4.text("©mak", in: user)
        }
    }

    private static func codecName(_ type: FourCharCode) -> String {
        switch type {
        case kCMVideoCodecType_H264: "H.264"
        case kCMVideoCodecType_HEVC: "HEVC"
        case kCMVideoCodecType_AppleProRes422: "ProRes 422"
        case kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ"
        case kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT"
        case kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy"
        case kCMVideoCodecType_AppleProRes4444: "ProRes 4444"
        case kCMVideoCodecType_AppleProResRAW: "ProRes RAW"
        case kCMVideoCodecType_JPEG: "Motion JPEG"
        default:
            String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: type >> $0) }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - RED and Blackmagic RAW

    private static func readRaw(_ file: URL, into details: inout ClipDetails) {
        guard let source = try? RawHelperSource(url: file) else { return }
        defer { source.close() }
        let info = source.info
        if info.width > 0 { details.width = info.width; details.height = info.height }
        if info.fps > 0 {
            details.fps = info.fps
            if info.frames > 0 { details.duration = Double(info.frames) / info.fps }
        }
        details.codec = info.formatName
        details.iso = info.iso.map(Double.init)
        details.whiteBalance = info.kelvin
        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { key in info.meta.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        details.camera = value("camera_type", "camera_model", "camera")
        details.lens = value("lens_type", "lens_name", "lens")
        if let shutter = value("shutter_value", "shutter") { details.shutter = seconds(shutter) }
        if details.iso == nil, let iso = value("iso") { details.iso = Double(iso) }
        details.lut = value("lut", "lut_name")
    }

    private static func rawPicture(_ file: URL, size: CGFloat) -> CGImage? {
        guard let source = try? RawHelperSource(url: file) else { return nil }
        defer { source.close() }
        var scale = 1
        while scale < 16, CGFloat(source.info.width / (scale * 2)) >= size { scale *= 2 }
        return try? source.displayFrame(0, scale: scale, settings: RawSettings())
    }

    // MARK: - XML beside the clip

    /// The camera's XML for a clip: Sony's C0001M01.XML in the same folder, or Canon's C0001.XML
    /// (both next to the clip, or Sony's in the folder above for XAVC S).
    private static func readSidecar(_ file: URL, into details: inout ClipDetails) {
        let stem = file.deletingPathExtension().lastPathComponent
        let folder = file.deletingLastPathComponent()
        let names = ["\(stem)M01.XML", "\(stem)M01.xml", "\(stem).XML", "\(stem).xml"]
        guard let url = names.map({ folder.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url), data.count < 2 << 20 else { return }
        let reader = SidecarXML()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return }
        details.camera = details.camera ?? reader.camera
        details.lens = details.lens ?? reader.lens
        details.fps = details.fps ?? reader.fps
        details.iso = details.iso ?? reader.iso
        details.shutter = details.shutter ?? reader.shutter
        details.whiteBalance = details.whiteBalance ?? reader.whiteBalance
        details.lut = details.lut ?? reader.lut
    }

    /// A shutter as seconds, from "1/50" or "0.02" (anything else is left out).
    static func seconds(_ text: String) -> Double? {
        let clean = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "s", with: "")
        if let slash = clean.firstIndex(of: "/"), let top = Double(clean[..<slash]), let bottom = Double(clean[clean.index(after: slash)...]), bottom > 0 {
            return top / bottom
        }
        return Double(clean).flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The few things a Sony or Canon XML says about a clip: `<Device modelName>`, `<Lens modelName>`,
/// the frame rate (`<VideoFrame captureFps="25p">`) and the `<Item name value>` camera settings.
private final class SidecarXML: NSObject, XMLParserDelegate {
    var camera: String?, lens: String?, lut: String?
    var fps: Double?, iso: Double?, shutter: Double?, whiteBalance: Double?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        switch name {
        case "Device":
            if let model = attributes["modelName"], !model.isEmpty { camera = [attributes["manufacturer"], model].compactMap { $0 }.joined(separator: " ") }
        case "Lens":
            lens = attributes["modelName"].flatMap { $0.isEmpty ? nil : $0 } ?? lens
        case "VideoFrame":
            if let rate = attributes["captureFps"] ?? attributes["formatFps"] {
                fps = Double(rate.filter { $0.isNumber || $0 == "." })
            }
        case "Item":
            guard let key = attributes["name"], let value = attributes["value"] else { return }
            switch key {
            case "ISOSensitivity", "ISO": iso = Double(value)
            case "ShutterSpeed_time": shutter = OffloadClips.seconds(value)
            case "WhiteBalance", "ColorTemperature": whiteBalance = whiteBalance ?? Double(value.filter { $0.isNumber || $0 == "." })
            case "LensModelName": lens = lens ?? (value.isEmpty ? nil : value)
            case "Gamma", "LUT", "LutName": lut = lut ?? (value.isEmpty ? nil : value)
            default: break
            }
        default: break
        }
    }
}

// MARK: - After a card

extension OffloadCenter {
    /// Off while the self-test times a copy without them.
    static var detailsOn = true

    nonisolated static var detailsFolder: URL { folder.appendingPathComponent("Details", isDirectory: true) }

    /// The clips of a finished card, once they're worked out (or read from the cache).
    func details(for job: UUID) -> [ClipDetails]? { clipDetails[job] }

    /// Reads a job's details back from the cache, if they were worked out in an earlier run.
    func loadDetails(_ id: UUID) async {
        guard clipDetails[id] == nil else { return }
        let url = Self.detailsFolder.appendingPathComponent("\(id.uuidString).json")
        let list = await Task.detached(priority: .utility) { try? JSONDecoder().decode([ClipDetails].self, from: Data(contentsOf: url)) }.value
        if let list, clipDetails[id] == nil { clipDetails[id] = list }
    }

    func forgetDetails(_ id: UUID) {
        clipDetails[id] = nil
        try? FileManager.default.removeItem(at: Self.detailsFolder.appendingPathComponent("\(id.uuidString).json"))
    }

    /// After a card is done: each clip's details from the first copy, in the background at utility
    /// priority (the copy never waits for it), and kept next to the job. A clip that can't be read
    /// is in the list with what's known.
    func workOutDetails(_ job: OffloadJob) {
        guard Self.detailsOn, job.quick != true,
              let root = job.targets.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return }
        let id = job.id
        let clips = job.files.filter { $0.problem == nil && OffloadClips.videoKinds.contains(($0.path as NSString).pathExtension.lowercased()) }
            .prefix(300).map { (card: $0.path, copy: job.destination(of: $0.path)) }
        Task.detached(priority: .utility) {
            var list: [ClipDetails] = []
            for clip in clips {
                var details = await OffloadClips.read(URL(fileURLWithPath: root).appendingPathComponent(clip.copy))
                details.path = clip.card
                list.append(details)
                // A breath between clips, so a disk that has another card to copy isn't kept busy.
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? FileManager.default.createDirectory(at: Self.detailsFolder, withIntermediateDirectories: true)
            try? JSONEncoder().encode(list).write(to: Self.detailsFolder.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
            let done = list
            await MainActor.run { OffloadCenter.shared.clipDetails[id] = done }
        }
    }
}
