import AVFoundation
import CoreImage
import SwiftUI

/// Raw Player: camera raw clips played natively, with their raw settings (ISO, white balance,
/// exposure) applied from the raw data, not baked in. RED (.R3D) and Blackmagic RAW go through
/// pluck-raw (the camera makers' own decoders, in their own process); CinemaDNG through Core Image.

/// How the picture is developed.
enum RawLook: String, CaseIterable, Identifiable, Sendable {
    /// Ready to watch: Rec.709.
    case video
    /// As the camera was set (its own look or LUT).
    case shot
    /// Flat, for grading: the maker's log.
    case log

    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .video: "Video"
        case .shot: "As Shot"
        case .log: "Log"
        }
    }
    /// The word pluck-raw uses.
    var helperName: String { self == .video ? "display" : rawValue }
}

/// The raw settings of a frame (nil: as shot).
struct RawSettings: Equatable, Sendable {
    var look = RawLook.video
    var iso: Int?
    var kelvin: Double?
    var tint: Double?
    var exposure: Double?
    /// A .cube LUT over the developed picture (a log to Rec.709, a show look).
    var lut: String?
}

/// What a clip is, and the ranges of its settings.
struct RawClipInfo: Sendable {
    var format: String
    var width: Int
    var height: Int
    var fps: Double
    var frames: Int
    var iso: Int?
    var isos: [Int] = []
    var kelvin: Double?
    var kelvinRange: ClosedRange<Double>?
    var tint: Double?
    var tintRange: ClosedRange<Double>?
    var exposure: Double?
    var exposureRange: ClosedRange<Double>?
    var meta: [String: String] = [:]
    /// The timecode of the first frame (edge / run record), and of the time of day, when recorded.
    var timecode: String?
    var absoluteTimecode: String?
    var audioChannels = 0
    /// For ordinary formats: what the picture is (ProRes 422 HQ, H.264, DPX sequence…).
    var codecName: String?

    /// Camera raw, with raw settings (ordinary movies only have exposure).
    var isRaw: Bool { ["r3d", "braw", "crm", "cdng", "prores"].contains(format) }

    var formatName: String {
        switch format {
        case "r3d": "REDCODE RAW"
        case "braw": "Blackmagic RAW"
        case "cdng": "CinemaDNG"
        case "prores": "ProRes RAW"
        default: codecName ?? format.uppercased()
        }
    }

    /// The camera, from the metadata the formats use.
    var camera: String? {
        for key in ["camera_type", "camera_model", "Camera Model", "camera_model_name", "Model"] {
            if let value = meta[key], !value.isEmpty { return value }
        }
        return nil
    }
}

/// A clip that gives frames.
protocol RawSource: AnyObject, Sendable {
    var info: RawClipInfo { get }
    /// One frame, at 1/scale of the size, developed with these settings.
    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage
    func close()
    /// Another decoder of the same clip, to decode frames side by side while playing (nil when
    /// this one can already decode several at once).
    func another() throws -> RawSource?
    /// The clip's sound as a file to play, if it has any.
    func audio() throws -> URL?
    /// A frame for the screen while playing: developed, in 8 bits.
    func displayFrame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage
}

extension RawSource {
    func another() throws -> RawSource? { nil }
    func audio() throws -> URL? { nil }

    func displayFrame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        RawPictures.forDisplay(try developed(index, scale: scale, settings: settings))
    }

    /// A frame with the LUT over it (what's shown, saved and exported).
    func developed(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        RawLUT.apply(try frame(index, scale: scale, settings: settings), lut: settings.lut)
    }
}

struct RawProblem: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

// MARK: - pluck-raw

/// A clip read by pluck-raw (RED, Blackmagic RAW), one helper process per clip.
final class RawHelperSource: RawSource, @unchecked Sendable {
    let info: RawClipInfo
    private let url: URL
    private let process = Process()
    private let input: FileHandle
    private let output: FileHandle
    private var pending = Data()
    private let buffer: URL
    private let mapped: UnsafeMutableRawPointer
    private let mappedSize: Int
    private let lock = NSLock()

    static var helper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pluck-raw")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The formats this Pluck was built with.
    static let formats: Set<String> = {
        guard let helper else { return [] }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["formats"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        // (Read to the end without waiting on the process: waiting runs the run loop, which can
        // redraw a view that asks for this again.)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return Set(reply?["formats"] as? [String] ?? [])
    }()

    init(url: URL) throws {
        guard let helper = Self.helper else { throw RawProblem(text: String(localized: "This Pluck was built without the raw decoder.")) }
        self.url = url
        process.executableURL = helper
        let toHelper = Pipe(), fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        try process.run()

        let reply: [String: Any]
        do {
            reply = try Self.ask(["op": "open", "path": url.path], input: input, output: output, pending: &pending)
        } catch {
            process.terminate()
            throw error
        }
        self.info = Self.info(from: reply, url: url)

        // One full-size frame of 16-bit RGBA, shared with the helper.
        mappedSize = max(info.width * info.height * 8, 8)
        buffer = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-raw-\(UUID().uuidString).frame")
        FileManager.default.createFile(atPath: buffer.path, contents: nil)
        let fd = open(buffer.path, O_RDWR)
        defer { if fd >= 0 { Darwin.close(fd) } }
        guard fd >= 0, ftruncate(fd, off_t(mappedSize)) == 0,
              let memory = mmap(nil, mappedSize, PROT_READ, MAP_SHARED, fd, 0), memory != MAP_FAILED else {
            process.terminate()
            throw RawProblem(text: String(localized: "There isn’t enough memory for this clip."))
        }
        mapped = memory
    }

    /// A clip's description from the helper's reply to opening it.
    static func info(from reply: [String: Any], url: URL) -> RawClipInfo {
        func number(_ key: String) -> Double? { (reply[key] as? NSNumber)?.doubleValue }
        func range(_ key: String) -> ClosedRange<Double>? {
            guard let pair = reply[key] as? [NSNumber], pair.count == 2, pair[0].doubleValue <= pair[1].doubleValue else { return nil }
            return pair[0].doubleValue...pair[1].doubleValue
        }
        var info = RawClipInfo(format: reply["format"] as? String ?? url.pathExtension.lowercased(),
                               width: Int(number("width") ?? 0), height: Int(number("height") ?? 0),
                               fps: number("fps") ?? 24, frames: Int(number("frames") ?? 0))
        info.iso = number("iso").map { Int($0) }
        info.isos = (reply["isos"] as? [NSNumber])?.map(\.intValue) ?? []
        info.kelvin = number("kelvin"); info.kelvinRange = range("kelvinRange")
        info.tint = number("tint"); info.tintRange = range("tintRange")
        info.exposure = number("exposure"); info.exposureRange = range("exposureRange")
        info.meta = reply["meta"] as? [String: String] ?? [:]
        func text(_ key: String) -> String? { (reply[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        info.timecode = text("timecode")
        info.absoluteTimecode = text("absoluteTimecode")
        info.audioChannels = (reply["audioChannels"] as? NSNumber)?.intValue ?? 0
        return info
    }

    deinit {
        close()
        munmap(mapped, mappedSize)
        try? FileManager.default.removeItem(at: buffer)
        // The sound made from the clip (not the camera's own .wav).
        if let audioFile, audioFile.lastPathComponent.hasPrefix("pluck-raw-") { try? FileManager.default.removeItem(at: audioFile) }
    }

    func close() {
        lock.withLock {
            guard process.isRunning else { return }
            try? input.write(contentsOf: Data("{\"op\":\"quit\"}\n".utf8))
            process.terminate()
        }
    }

    private var audioFile: URL?

    /// The sound: from the clip itself, or a .wav the camera wrote next to it (in the .RDC folder).
    func audio() throws -> URL? {
        try lock.withLock {
            if let audioFile { return audioFile }
            if info.audioChannels > 0 {
                let to = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-raw-\(UUID().uuidString).wav")
                _ = try Self.ask(["op": "audio", "to": to.path], input: input, output: output, pending: &pending)
                audioFile = to
                return to
            }
            let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_001", with: "")
            let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
            audioFile = files.first { $0.pathExtension.lowercased() == "wav" && $0.deletingPathExtension().lastPathComponent.hasPrefix(base) }
            return audioFile
        }
    }

    /// The camera makers' decoders use a few cores per frame: more of them in parallel play faster.
    func another() throws -> RawSource? { try RawHelperSource(url: url) }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        try frame(index, scale: scale, settings: settings, eight: false)
    }

    /// Straight in 8 bits from the decoder (the LUT, if any, over it).
    func displayFrame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        let picture = try frame(index, scale: scale, settings: settings, eight: true)
        return settings.lut == nil ? picture : RawPictures.forDisplay(RawLUT.apply(picture, lut: settings.lut))
    }

    private func frame(_ index: Int, scale: Int, settings: RawSettings, eight: Bool) throws -> CGImage {
        try lock.withLock {
            var request: [String: Any] = ["op": "frame", "index": index, "scale": scale, "look": settings.look.helperName,
                                          "buffer": buffer.path, "size": mappedSize]
            if eight { request["depth"] = 8 }
            if let iso = settings.iso { request["iso"] = iso }
            if let kelvin = settings.kelvin { request["kelvin"] = kelvin }
            if let tint = settings.tint { request["tint"] = tint }
            if let exposure = settings.exposure { request["exposure"] = exposure }
            let reply = try Self.ask(request, input: input, output: output, pending: &pending)
            let width = (reply["width"] as? NSNumber)?.intValue ?? 0, height = (reply["height"] as? NSNumber)?.intValue ?? 0
            // (An older helper ignores the 8-bit request: it says which it wrote.)
            let eight = (reply["depth"] as? NSNumber)?.intValue == 8
            let pixel = eight ? 4 : 8
            guard width > 0, height > 0, width * height * pixel <= mappedSize else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
            let data = Data(bytes: mapped, count: width * height * pixel)
            let space = settings.look == .video ? CGColorSpace(name: CGColorSpace.itur_709)! : CGColorSpace(name: CGColorSpace.sRGB)!
            let layout = eight ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: eight ? 8 : 16, bitsPerPixel: pixel * 8, bytesPerRow: width * pixel,
                                      space: space, bitmapInfo: CGBitmapInfo(rawValue: layout),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
            }
            return image
        }
    }

    /// One request and its reply (a line of JSON each way).
    static func ask(_ request: [String: Any], input: FileHandle, output: FileHandle, pending: inout Data) throws -> [String: Any] {
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        do { try input.write(contentsOf: line) } catch { throw RawProblem(text: String(localized: "The raw decoder stopped.")) }
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let answer = pending[pending.startIndex..<end]
                pending.removeSubrange(pending.startIndex...end)
                guard let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { continue }
                if (reply["ok"] as? Bool) != true {
                    throw RawProblem(text: reply["problem"] as? String ?? String(localized: "The raw decoder couldn’t read this."))
                }
                return reply
            }
            let more = output.availableData
            if more.isEmpty { throw RawProblem(text: String(localized: "The raw decoder stopped.")) }
            pending.append(more)
        }
    }
}

// MARK: - CinemaDNG

/// A CinemaDNG clip: a folder of numbered DNG frames, each developed by Core Image's raw engine.
final class DNGSequenceSource: RawSource, @unchecked Sendable {
    let info: RawClipInfo
    private let frames: [URL]
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

    init(url: URL) throws {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        frames = files.filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let first = frames.first, let filter = CIRAWFilter(imageURL: first) else {
            throw RawProblem(text: String(localized: "There are no DNG frames in this folder."))
        }
        let size = filter.nativeSize
        var info = RawClipInfo(format: "cdng", width: Int(size.width), height: Int(size.height),
                               fps: Self.frameRate(first) ?? 24, frames: frames.count)
        info.kelvin = Double(filter.neutralTemperature)
        info.kelvinRange = 2000...50000
        info.tint = Double(filter.neutralTint)
        info.tintRange = -150...150
        info.exposure = 0
        info.exposureRange = -5...5
        if let source = CGImageSourceCreateWithURL(first as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                if let make = tiff[kCGImagePropertyTIFFMake] as? String { info.meta["Make"] = make }
                if let model = tiff[kCGImagePropertyTIFFModel] as? String { info.meta["Model"] = model }
            }
            if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first {
                info.meta["ISO"] = iso.stringValue
            }
        }
        info.meta["Frames"] = "\(frames.count)"
        self.info = info
    }

    /// CinemaDNG's FrameRate tag (51044), when the frames have it.
    private static func frameRate(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] else { return nil }
        for (key, value) in dng where (key as String).localizedCaseInsensitiveContains("FrameRate") {
            if let number = value as? NSNumber { return number.doubleValue }
            if let pair = value as? [NSNumber], pair.count == 2, pair[1].doubleValue > 0 { return pair[0].doubleValue / pair[1].doubleValue }
        }
        return nil
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        guard frames.indices.contains(index), let filter = CIRAWFilter(imageURL: frames[index]) else {
            throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
        }
        filter.scaleFactor = Float(1) / Float(max(scale, 1))
        if let kelvin = settings.kelvin { filter.neutralTemperature = Float(kelvin) }
        if let tint = settings.tint { filter.neutralTint = Float(tint) }
        if let exposure = settings.exposure { filter.exposure = Float(exposure) }
        if settings.look == .log {
            // Flat: no tone curve, highlights kept.
            filter.baselineExposure = 0
            filter.boostAmount = 0
            filter.isGamutMappingEnabled = false
        }
        guard let image = filter.outputImage,
              let made = context.createCGImage(image, from: image.extent, format: .RGBA16,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw RawProblem(text: String(localized: "The frame couldn’t be decoded."))
        }
        return made
    }

    func close() {}
}

// MARK: - ProRes RAW

/// ProRes RAW, which macOS decodes itself: the frames from AVFoundation, with exposure on top.
final class ProResRawSource: RawSource, @unchecked Sendable {
    let info: RawClipInfo
    private let generator: AVAssetImageGenerator
    private let context = CIContext()

    /// Whether a movie is ProRes RAW.
    static func isProResRaw(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let description = track.formatDescriptions.first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription)
        return codec == kCMVideoCodecType_AppleProResRAW || codec == kCMVideoCodecType_AppleProResRAWHQ
    }

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw RawProblem(text: String(localized: "This movie has no picture.")) }
        generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let size = track.naturalSize
        let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 24)
        var info = RawClipInfo(format: "prores", width: Int(size.width), height: Int(size.height), fps: fps,
                               frames: max(Int((asset.duration.seconds * fps).rounded()), 1))
        info.exposure = 0
        info.exposureRange = -5...5
        self.info = info
    }

    func frame(_ index: Int, scale: Int, settings: RawSettings) throws -> CGImage {
        generator.maximumSize = CGSize(width: info.width / max(scale, 1), height: info.height / max(scale, 1))
        let at = CMTime(seconds: (Double(index) + 0.5) / info.fps, preferredTimescale: 600)
        let image = try generator.copyCGImage(at: at, actualTime: nil)
        guard let exposure = settings.exposure, exposure != 0 else { return image }
        let adjusted = CIImage(cgImage: image).applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        return context.createCGImage(adjusted, from: adjusted.extent) ?? image
    }

    func close() {}
}

// MARK: - Opening

enum RawFormats {
    /// Raw video files (not photos), which Pluck opens in Raw Player.
    static func isRawVideo(_ url: URL) -> Bool { ["r3d", "braw", "crm"].contains(url.pathExtension.lowercased()) }

    /// Shows a clip in Raw Player.
    @MainActor static func show(_ url: URL) {
        RawPlayerView.openFile = url
        StudioNavigator.shared.open(.rawPlayer)
        AppDelegate.openMainWindow?()
        NotificationCenter.default.post(name: RawPlayerView.openNotification, object: url)
    }

    /// The extensions Pluck plays as raw (with the decoders this Pluck has).
    static var extensions: Set<String> { RawHelperSource.formats.union(["dng"]) }


    /// A RED take the camera split into several files (…_001.R3D, …_002.R3D): opened from its
    /// first, the whole take plays. For a later file: the first, and how far into the take that
    /// file starts (by size: REDCODE runs at a steady rate).
    nonisolated static func spanned(_ url: URL) -> (first: URL, start: Double)? {
        guard url.pathExtension.lowercased() == "r3d" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard let mark = name.range(of: "_[0-9]{3}$", options: .regularExpression), name[mark] != "_001" else { return nil }
        let stem = String(name[..<mark.lowerBound])
        let folder = url.deletingLastPathComponent()
        let parts = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "r3d" && $0.deletingPathExtension().lastPathComponent.range(of: "^" + NSRegularExpression.escapedPattern(for: stem) + "_[0-9]{3}$", options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = parts.first, first != url else { return nil }
        func size(_ file: URL) -> Double { Double((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let total = parts.map(size).reduce(0, +)
        let before = parts.prefix { $0 != url }.map(size).reduce(0, +)
        return (first, total > 0 ? before / total : 0)
    }

    /// The clip at a URL: a file, or a folder (an .RDC folder, a CinemaDNG folder, an image
    /// sequence).
    static func open(_ url: URL) throws -> RawSource {
        var url = url
        if url.hasDirectoryPath {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            // RED: the clip's first file.
            if let first = files.filter({ $0.pathExtension.lowercased() == "r3d" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                url = first
            } else if files.contains(where: { $0.pathExtension.lowercased() == "dng" }) {
                return try DNGSequenceSource(url: url)
            } else {
                return try sequence(ImageSequenceSource.files(in: url), from: url)
            }
        }
        let kind = url.pathExtension.lowercased()
        switch kind {
        case "r3d", "braw", "crm":
            guard RawHelperSource.formats.contains(kind) else {
                throw RawProblem(text: String(localized: "This Pluck can’t play this kind of raw file yet."))
            }
            return try RawHelperSource(url: url)
        case "dng":
            return try DNGSequenceSource(url: url)
        case _ where ImageSequenceSource.extensions.contains(kind) || kind == "dpx":
            // One image of a sequence: the sequence.
            return try sequence(ImageSequenceSource.files(in: url.deletingLastPathComponent(), chosen: url), from: url)
        default:
            if kind == "mov", ProResRawSource.isProResRaw(url) { return try ProResRawSource(url: url) }
            if MovieSource.canDecode(url), let movie = try? MovieSource(url: url) {
                // macOS says it can, but some it can't after all (H.264 4:4:4): tried on the
                // first frame, else ffmpeg.
                if RawTools.ffmpeg == nil || (try? movie.frame(0, scale: 8, settings: RawSettings())) != nil { return movie }
                movie.close()
            }
            return try FFmpegSource(url: url)
        }
    }

    /// Numbered images: macOS reads TIFF, EXR, PNG and JPEG; ffmpeg reads DPX.
    private static func sequence(_ files: [URL], from url: URL) throws -> RawSource {
        guard let first = files.first else { throw RawProblem(text: String(localized: "This isn’t a clip Pluck can play.")) }
        if first.pathExtension.lowercased() == "dpx" {
            // ffmpeg stops at a gap in the numbers: with gaps, every file in order (the gaps closed up, and listed).
            let missing = ImageSequenceSource.numbered(files).missing
            guard let input = missing.isEmpty ? FFmpegSource.sequenceInput(files, fps: 24) : FFmpegSource.listInput(files, fps: 24)
            else { throw RawProblem(text: String(localized: "These images can’t be read.")) }
            let source = try FFmpegSource(url: url, input: input)
            if !missing.isEmpty { source.noteMissing(ImageSequenceSource.ranges(missing)) }
            return source
        }
        return try ImageSequenceSource(files: files)
    }
}

// MARK: - The player

@MainActor
@Observable
final class RawPlayer {
    private(set) var url: URL?
    private(set) var info: RawClipInfo?
    /// The picture showing (handed straight to the view's layer, not observed: a playing clip
    /// mustn't redraw the page).
    @ObservationIgnored private(set) var currentImage: CGImage?
    @ObservationIgnored var present: ((CGImage) -> Void)?
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var opening = false
    private(set) var problem: String?
    /// Frames shown a second while playing (it keeps up when this is the clip's rate).
    private(set) var playbackRate: Double = 0
    var settings = RawSettings() {
        didSet {
            guard settings != oldValue else { return }
            if isPlaying { restartPlayback() } else { show(index) }
        }
    }
    /// The size frames are decoded at while playing (1, 2, 4 or 8: full, half…; 0 is automatic:
    /// the largest that keeps up); still frames are full size.
    var playScale = 0 {
        didSet {
            autoScale = initialScale
            if isPlaying { restartPlayback() }
        }
    }
    /// What automatic plays at now, and the smallest it may go to (raised when playing fell behind).
    private(set) var autoScale = 4
    @ObservationIgnored private var autoFloor = 1
    /// The picture's width on screen, in pixels (set by the view).
    @ObservationIgnored var viewPixels = 0.0

    /// The size that fills the picture on screen (no point decoding more), unless that fell behind.
    private var bestScale: Int {
        guard let width = info?.width, viewPixels > 0 else { return max(initialScale, autoFloor) }
        var scale = 1
        while scale < 8 && Double(width) / Double(scale * 2) >= viewPixels * 0.9 { scale *= 2 }
        return max(scale, autoFloor)
    }
    var effectivePlayScale: Int { playScale == 0 ? autoScale : playScale }
    var stillScale = 1 { didSet { if !isPlaying { show(index) } } }
    var loops = true

    /// In and out points (frames), for playing a part over and exporting it.
    private(set) var inPoint: Int?
    private(set) var outPoint: Int?
    var range: ClosedRange<Int> {
        let a = min(inPoint ?? 0, max(frames - 1, 0))
        return a...max(outPoint ?? (frames - 1), a)
    }

    /// The clip's sound (its own, or the camera's .wav next to it).
    private(set) var hasAudio = false
    var muted = false { didSet { audioPlayer?.volume = muted ? 0 : 1 } }
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?

    /// How the clip's time is shown.
    enum TimecodeMode: String, CaseIterable, Identifiable {
        case source, timeOfDay, frames, elapsed
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .source: "Timecode"
            case .timeOfDay: "Time of Day"
            case .frames: "Frames"
            case .elapsed: "From the Start"
            }
        }
    }
    var timecodeMode = TimecodeMode.source

    /// How far an export is, while one runs.
    private(set) var exportProgress: Double?
    private(set) var exported: URL?
    private(set) var exportProblem: String?
    @ObservationIgnored private var exportStop: RawExport.Stop?

    @ObservationIgnored private var source: RawSource?
    /// More decoders of the clip while playing (frames decoded side by side).
    @ObservationIgnored private var helpers: [RawSource] = []
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pipeline: RawFramePipeline?
    @ObservationIgnored private lazy var ticker = DisplayTicker { [weak self] in self?.tick() }
    /// Playback's state: where it started, its clock (nil while the first frames decode), the
    /// last position shown, where the sound was started and the next loop.
    @ObservationIgnored private var playStart = 0
    @ObservationIgnored private var clock: Date?
    @ObservationIgnored private var prerollSince = Date.now
    @ObservationIgnored private var lastShown = -1
    @ObservationIgnored private var audioPosition = 0
    @ObservationIgnored private var audioFrame = 0
    @ObservationIgnored private var nextWrap = 0
    @ObservationIgnored private var shownSince = Date.now
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private var slowSeconds = 0

    /// Decoders a clip gets in all (the camera makers' decoders use a few cores per frame).
    private static var decoderCount: Int { min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 6) }

    /// The play size to start at for this clip.
    private var initialScale: Int {
        let width = info?.width ?? 0
        return width > 7000 ? 8 : width > 3000 ? 4 : width > 1920 ? 2 : 1
    }

    var frames: Int { info?.frames ?? 0 }
    var fps: Double { max(info?.fps ?? 24, 1) }

    func open(_ url: URL) {
        stop()
        source?.close()
        source = nil
        audioPlayer?.stop()
        audioPlayer = nil
        hasAudio = false
        inPoint = nil
        outPoint = nil
        for helper in helpers { helper.close() }
        helpers = []
        info = nil
        currentImage = nil
        problem = nil
        opening = true
        // A later file of a RED take: the whole take, from where that file starts.
        let spanned = RawFormats.spanned(url)
        let url = spanned?.first ?? url
        self.url = url
        Self.trace("open")
        RawTools.prepare()
        Task {
            let result: Result<RawSource, Error> = await Task.detached(priority: .userInitiated) {
                Result { try RawFormats.open(url) }
            }.value
            opening = false
            switch result {
            case .success(let source):
                self.source = source
                info = source.info
                settings = RawSettings()
                autoFloor = 1
                autoScale = initialScale
                stillScale = 1
                index = min(Int((spanned?.start ?? 0) * Double(source.info.frames)), max(source.info.frames - 1, 0))
                show(index)
                loadAudio(source)
                prepareDecoders(source)
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    /// Closes the clip and goes back to no clip (the folder it came from, if any).
    func eject() {
        close()
        info = nil
        url = nil
        currentImage = nil
        problem = nil
        index = 0
        inPoint = nil
        outPoint = nil
    }

    func close() {
        stop()
        endPlayback()
        audioPlayer?.stop()
        audioPlayer = nil
        source?.close()
        source = nil
        for helper in helpers { helper.close() }
        helpers = []
        hasAudio = false
    }

    /// The other decoders start now, so playing (and the quick first picture of a frame) doesn't
    /// wait for them.
    private func prepareDecoders(_ source: RawSource) {
        guard source is RawHelperSource, helpers.isEmpty else { return }
        let count = Self.decoderCount - 1
        Task {
            let made = await Task.detached(priority: .userInitiated) { () -> [RawSource] in
                (0..<count).compactMap { _ in (try? source.another()) ?? nil }
            }.value
            guard self.source === source else { made.forEach { $0.close() }; return }
            helpers = made
        }
    }

    private func loadAudio(_ source: RawSource) {
        Task {
            let file = await Task.detached(priority: .utility) { try? source.audio() }.value
            guard let file, self.source === source, let player = try? AVAudioPlayer(contentsOf: file) else { return }
            player.prepareToPlay()
            player.volume = muted ? 0 : 1
            audioPlayer = player
            hasAudio = true
        }
    }

    // MARK: In and out

    func markIn() {
        inPoint = index
        if let outPoint, outPoint < index { self.outPoint = nil }
    }

    func markOut() {
        outPoint = index
        if let inPoint, inPoint > index { self.inPoint = nil }
    }

    func clearIn() { inPoint = nil }
    func clearOut() { outPoint = nil }

    // MARK: Timecode

    /// The nominal rate timecode counts in (24 for 23.976…).
    private var timecodeRate: Int { max(Int(fps.rounded()), 1) }

    /// A frame's time in the chosen way: the clip's own timecode (or the time of day), its frame
    /// number, or the time from the start.
    func label(_ frame: Int) -> String {
        switch timecodeMode {
        case .source, .timeOfDay:
            let start = (timecodeMode == .timeOfDay ? info?.absoluteTimecode : nil) ?? info?.timecode
            let offset = start.flatMap { Self.frames(in: $0, rate: timecodeRate) } ?? 0
            // Drop-frame timecode (29.97, 59.94: "01:00:00;00") counts on as drop-frame.
            return Self.timecode(offset + frame, rate: timecodeRate, dropFrame: start?.contains(";") == true)
        case .frames:
            return "\(frame)"
        case .elapsed:
            return Self.timecode(frame, rate: timecodeRate)
        }
    }

    /// Goes to a timecode ("01:00:05:12", "5:12"…) or a frame number, in the way time is shown.
    @discardableResult
    func jump(to text: String) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespaces)
        var target: Int?
        if !clean.contains(":") && !clean.contains(";"), let number = Int(clean) {
            target = timecodeMode == .frames ? number : nil
        }
        if target == nil, let total = Self.frames(in: clean, rate: timecodeRate) {
            switch timecodeMode {
            case .source, .timeOfDay:
                let start = (timecodeMode == .timeOfDay ? info?.absoluteTimecode : nil) ?? info?.timecode
                // A short one ("5:12") is within the clip; a full one is the clip's own.
                let parts = clean.split(whereSeparator: { $0 == ":" || $0 == ";" }).count
                target = parts == 4 ? total - (start.flatMap { Self.frames(in: $0, rate: timecodeRate) } ?? 0) : total
            default:
                target = total
            }
        }
        guard let target, target >= 0, target < frames else { return false }
        stop()
        show(target)
        return true
    }

    /// Frames in a timecode ("HH:MM:SS:FF", or fewer parts from the right).
    /// Frames a drop-frame count leaves out each minute (but every tenth): 2 at 30, 4 at 60.
    nonisolated private static func dropped(_ rate: Int) -> Int { rate % 30 == 0 ? rate / 15 : 0 }

    /// A timecode as frames from 00:00:00:00. A ";" (01:00:00;00) is drop-frame timecode, whose
    /// numbers skip a few frames each minute to keep up with the clock at 29.97 or 59.94 fps.
    nonisolated static func frames(in timecode: String, rate: Int) -> Int? {
        let parts = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, !parts.contains(nil) else { return nil }
        let values = [Int](repeating: 0, count: 4 - parts.count) + parts.map { $0! }
        var total = ((values[0] * 60 + values[1]) * 60 + values[2]) * rate + values[3]
        if timecode.contains(";") {
            let minutes = values[0] * 60 + values[1]
            total -= dropped(rate) * (minutes - minutes / 10)
        }
        return total
    }

    nonisolated static func timecode(_ total: Int, rate: Int, dropFrame: Bool = false) -> String {
        var frames = max(total, 0)
        let drop = dropFrame ? dropped(rate) : 0
        if drop > 0 {
            // Back to the numbers on the clock: the skipped ones added in.
            let perMinute = rate * 60 - drop, perTen = rate * 600 - drop * 9
            let tens = frames / perTen, rest = frames % perTen
            frames += drop * 9 * tens + (rest < drop ? 0 : drop * ((rest - drop) / perMinute))
        }
        let seconds = frames / rate
        return String(format: drop > 0 ? "%02d:%02d:%02d;%02d" : "%02d:%02d:%02d:%02d",
                      seconds / 3600 % 24, seconds / 60 % 60, seconds % 60, frames % rate)
    }

    /// Settings back to how the clip was shot.
    func resetSettings() {
        settings = RawSettings(look: settings.look)
    }

    private func display(_ picture: CGImage) {
        currentImage = picture
        present?(picture)
        Self.trace("shown \(index) \(picture.width)")
    }

    /// Tests (-PluckScreenshotTrace <file> in the raw scene): when each picture is shown.
    @ObservationIgnored private static let traceFile: FileHandle? = {
        guard ScreenshotMode.scene == "raw", let path = UserDefaults.standard.string(forKey: "PluckScreenshotTrace") else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static func trace(_ line: String) {
        guard let traceFile else { return }
        traceFile.write(Data(String(format: "%.4f %@\n", Date.now.timeIntervalSinceReferenceDate, line).utf8))
    }

    /// Decodes and shows one frame (the latest asked for wins). A big clip shows a quick small
    /// picture first (on another decoder), then the full one.
    func show(_ frame: Int, scale: Int? = nil) {
        guard let source, frames > 0 else { return }
        let frame = min(max(frame, 0), frames - 1)
        index = frame
        generation += 1
        let mine = generation, settings = settings, scale = scale ?? stillScale
        let quick = scale < effectivePlayScale && (info?.width ?? 0) > 2000 ? effectivePlayScale : nil
        let quickDecoder = helpers.first ?? source
        showTask?.cancel()
        showTask = Task {
            if let quick {
                let fast = await Task.detached(priority: .userInitiated) { try? quickDecoder.developed(frame, scale: quick, settings: settings) }.value
                guard mine == generation else { return }
                if let fast { display(fast) }
            }
            let made = await Task.detached(priority: .userInitiated) { Result { try source.developed(frame, scale: scale, settings: settings) } }.value
            guard mine == generation else { return }
            switch made {
            case .success(let picture): display(picture); problem = nil
            case .failure(let error): problem = error.localizedDescription
            }
        }
    }

    func step(_ by: Int) {
        stop()
        show(index + by)
    }

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard source != nil, frames > 1, !isPlaying else { return }
        if index >= range.upperBound || !range.contains(index) { index = range.lowerBound }
        isPlaying = true
        restartPlayback()
    }

    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        endPlayback()
        // The still frame at full quality.
        show(index)
    }

    private func endPlayback() {
        ticker.stop()
        pipeline?.stop()
        pipeline = nil
        audioPlayer?.pause()
    }

    /// Starts (or restarts, after a change) playing from the current frame: the decoders fill a
    /// few frames ahead, then the clock starts and the screen's refresh shows each frame on time.
    private func restartPlayback() {
        pipeline?.stop()
        guard let source else { return }
        let range = range
        let start = range.contains(index) && index < range.upperBound ? index : range.lowerBound
        if playScale == 0 { autoScale = bestScale }
        pipeline = RawFramePipeline(decoders: [source] + helpers, start: start, range: range, scale: effectivePlayScale,
                                    settings: settings, loops: loops,
                                    frameBytes: (info?.width ?? 0) * (info?.height ?? 0) * 4 / max(effectivePlayScale * effectivePlayScale, 1))
        audioPlayer?.pause()
        playStart = start
        lastShown = start - 1
        nextWrap = range.upperBound + 1
        clock = nil
        prerollSince = .now
        shown = 0
        shownSince = .now
        slowSeconds = 0
        ticker.start()
    }

    /// Every refresh of the screen while playing: shows the frame that's due, if it's decoded.
    private func tick() {
        guard isPlaying, let pipeline else { return }
        let now = Date.now
        if clock == nil {
            // A few frames ready first (or a moment's wait), so it doesn't stutter off the line.
            let wanted = min(3, pipeline.ahead)
            guard pipeline.buffered(from: playStart) >= wanted || now.timeIntervalSince(prerollSince) > 0.6 else { return }
            clock = now
            startAudio(position: playStart, frame: playStart)
        }
        guard let clock else { return }
        // The sound leads when it plays; otherwise the clock.
        var due = playStart + Int(now.timeIntervalSince(clock) * fps)
        if let audio = audioPlayer, audio.isPlaying {
            due = audioPosition + Int((audio.currentTime * fps - Double(audioFrame)).rounded(.down))
        }
        if loops, due >= nextWrap {
            startAudio(position: nextWrap, frame: range.lowerBound)
            nextWrap += range.count
        }
        if !loops, due > range.upperBound {
            isPlaying = false
            endPlayback()
            show(range.upperBound)
            return
        }
        guard due > lastShown else { return }
        if let picture = pipeline.take(due) {
            index = pipeline.frame(at: due)
            display(picture)
            lastShown = due
            shown += 1
        }
        // Frames shown a second; automatic size steps down when it can't keep up.
        let elapsed = now.timeIntervalSince(shownSince)
        if elapsed >= 1 {
            playbackRate = Double(shown) / elapsed
            shown = 0
            shownSince = now
            slowSeconds = playbackRate < fps * 0.9 ? slowSeconds + 1 : 0
            if playScale == 0, slowSeconds >= 2, autoScale < 16 {
                autoFloor = autoScale * 2
                restartPlayback()
            }
        }
    }

    private func startAudio(position: Int, frame: Int) {
        audioPosition = position
        audioFrame = frame
        guard let audio = audioPlayer else { return }
        audio.currentTime = Double(frame) / fps
        if audio.currentTime < audio.duration { audio.play() } else { audio.pause() }
    }

    /// The whole clip as a movie, with the current settings.
    func export(to url: URL, codec: RawExport.Codec, scale: Int) {
        guard let path = self.url, exportProgress == nil else { return }
        stop()
        exportProgress = 0
        exported = nil
        exportProblem = nil
        let settings = settings, range = range
        let stop = RawExport.Stop()
        exportStop = stop
        Task {
            // Its own decoder, so playing on carries on beside it.
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let source = try RawFormats.open(path)
                    defer { source.close() }
                    try RawExport.write(source, to: url, codec: codec, scale: scale, settings: settings, frames: range, stop: stop) { value in
                        Task { @MainActor in if self.exportProgress != nil { self.exportProgress = value } }
                    }
                }
            }.value
            exportProgress = nil
            exportStop = nil
            switch result {
            case .success:
                if FileManager.default.fileExists(atPath: url.path) {
                    exported = url
                    _ = AppDelegate.shared?.manager.addLocalFiles([url])
                }
            case .failure(let error):
                exportProblem = error.localizedDescription
            }
        }
    }

    func stopExport() { exportStop?.stop() }

    /// The current frame at full size as a PNG in a temporary folder, named for the clip and its
    /// time, to drag out to Finder or another app.
    func frameFile() async throws -> URL {
        guard let source, let url else { throw RawProblem(text: String(localized: "The frame couldn’t be saved.")) }
        let frame = index, settings = settings
        let name = url.deletingPathExtension().lastPathComponent + " " + label(frame).replacingOccurrences(of: ":", with: "-") + ".png"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Pluck Frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try await Task.detached(priority: .userInitiated) {
            let image = try source.developed(frame, scale: 1, settings: settings)
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else {
                throw RawProblem(text: String(localized: "The frame couldn’t be saved."))
            }
            CGImageDestinationAddImage(destination, image, nil)
            if !CGImageDestinationFinalize(destination) { throw RawProblem(text: String(localized: "The frame couldn’t be saved.")) }
        }.value
        return file
    }

    /// The current frame at full size and full quality, as a 16-bit TIFF.
    func saveFrame(to url: URL) async throws {
        guard let source else { return }
        let frame = index, settings = settings
        try await Task.detached(priority: .userInitiated) {
            let image = try source.developed(frame, scale: 1, settings: settings)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
                throw RawProblem(text: String(localized: "The frame couldn’t be saved."))
            }
            CGImageDestinationAddImage(destination, image, nil)
            if !CGImageDestinationFinalize(destination) { throw RawProblem(text: String(localized: "The frame couldn’t be saved.")) }
        }.value
    }

    /// The timecode of a frame (from the start of the clip).
    func timecode(_ frame: Int) -> String {
        let rate = Int(fps.rounded())
        let seconds = frame / max(rate, 1)
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % max(rate, 1))
    }
}

// MARK: - Exporting

/// A raw clip written as an ordinary movie (ProRes or H.264) with its raw settings applied, for
/// editing anywhere (the Editor, DaVinci Resolve, Final Cut Pro).
enum RawExport {
    enum Codec: String, CaseIterable, Identifiable {
        case proresHQ, prores, proresProxy, h264
        var id: String { rawValue }
        var label: String {
            switch self {
            case .proresHQ: "ProRes 422 HQ"
            case .prores: "ProRes 422"
            case .proresProxy: "ProRes 422 Proxy"
            case .h264: "H.264"
            }
        }
        var type: AVVideoCodecType {
            switch self {
            case .proresHQ: .proRes422HQ
            case .prores: .proRes422
            case .proresProxy: .proRes422Proxy
            case .h264: .h264
            }
        }
        var fileExtension: String { self == .h264 ? "mp4" : "mov" }
    }

    /// Writes frames from…to (inclusive), reporting how far it is; stops when the task is cancelled.
    /// Set to stop an export.
    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func stop() { lock.withLock { stopped = true } }
        var isStopped: Bool { lock.withLock { stopped } }
    }

    static func write(_ source: RawSource, to url: URL, codec: Codec, scale: Int, settings: RawSettings, frames: ClosedRange<Int>,
                      stop: Stop, progress: @escaping @Sendable (Double) -> Void) throws {
        // Written under a hidden name beside it and named when it's whole, so a stopped or failed
        // export (or Pluck quitting) never leaves a broken movie under the real name.
        let partial = url.deletingLastPathComponent().appendingPathComponent("." + url.deletingPathExtension().lastPathComponent + ".pluckpart." + url.pathExtension)
        try? FileManager.default.removeItem(at: partial)
        do {
            guard try writeMovie(source, to: partial, codec: codec, scale: scale, settings: settings, frames: frames, stop: stop, progress: progress) else {
                try? FileManager.default.removeItem(at: partial)
                return
            }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// The movie itself: false when it was stopped.
    private static func writeMovie(_ source: RawSource, to url: URL, codec: Codec, scale: Int, settings: RawSettings, frames: ClosedRange<Int>,
                                   stop: Stop, progress: @escaping @Sendable (Double) -> Void) throws -> Bool {
        let info = source.info
        let width = info.width / max(scale, 1) / 2 * 2, height = info.height / max(scale, 1) / 2 * 2
        let writer = try AVAssetWriter(outputURL: url, fileType: codec == .h264 ? .mp4 : .mov)
        var video: [String: Any] = [AVVideoCodecKey: codec.type, AVVideoWidthKey: width, AVVideoHeightKey: height,
                                    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        if codec == .h264 {
            video[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: max(width * height * 12, 8_000_000)]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RawProblem(text: String(localized: "The export couldn’t be written.")) }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        let space = CGColorSpace(name: CGColorSpace.itur_709)!
        let rate = CMTimeScale(max(Int((info.fps * 1000).rounded()), 1))
        for (n, index) in frames.enumerated() {
            if stop.isStopped { writer.cancelWriting(); return false }
            let picture: CGImage
            do {
                picture = try source.developed(index, scale: scale, settings: settings)
            } catch {
                writer.cancelWriting()
                throw RawProblem(text: String(localized: "Frame \(index) couldn’t be read, so the export stopped there."))
            }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? RawProblem(text: String(localized: "The export couldn’t be written.")) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RawProblem(text: String(localized: "There isn’t enough memory for this clip.")) }
            var image = CIImage(cgImage: picture)
            // Fitted to the movie's (even) size.
            image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
            context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space)
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            // Frame n at n × 1000 / (fps × 1000) seconds.
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n) * 1000, timescale: rate)) else {
                throw writer.error ?? RawProblem(text: String(localized: "The export couldn’t be written."))
            }
            progress(Double(n + 1) / Double(frames.count))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? RawProblem(text: String(localized: "The export couldn’t be written.")) }
        return true
    }
}
