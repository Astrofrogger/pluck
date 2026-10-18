import CoreGraphics
import Foundation

/// A raw clip for Quick Look (Finder's preview and thumbnails), read by pluck-raw's decoders built
/// in: the same requests as Pluck's Raw Player, frames through a mapped file.
final class RawClip: @unchecked Sendable {
    let width: Int
    let height: Int
    let fps: Double
    let frames: Int
    let format: String
    let camera: String?
    let startTimecode: String?

    private let url: URL
    private let buffer: URL
    private let mapped: UnsafeMutableRawPointer
    private let mappedSize: Int

    /// The decoders are built in (Quick Look may not start programs) and hold one clip at a time:
    /// requests go one by one, and the clip is opened again when another one was in between.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var openPath: String?
    nonisolated(unsafe) private static var librariesSet = false

    /// The extension's own copy of the decoders (its sandbox can't read Pluck's).
    private static var libraries: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Decoders") }

    init(url: URL) throws {
        self.url = url
        let reply = try Self.lock.withLock { try Self.openClip(url) }
        func number(_ key: String) -> Double { (reply[key] as? NSNumber)?.doubleValue ?? 0 }
        width = Int(number("width")); height = Int(number("height"))
        fps = max(number("fps"), 1); frames = Int(number("frames"))
        format = reply["format"] as? String ?? ""
        let meta = reply["meta"] as? [String: String] ?? [:]
        camera = meta["camera_type"] ?? meta["camera_model"] ?? meta["Camera Model"]
        startTimecode = meta["start_edge_timecode"] ?? meta["timecode"]
        mappedSize = max(width * height * 8, 8)
        buffer = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-ql-\(UUID().uuidString).frame")
        FileManager.default.createFile(atPath: buffer.path, contents: nil)
        let fd = open(buffer.path, O_RDWR)
        defer { if fd >= 0 { Darwin.close(fd) } }
        guard fd >= 0, ftruncate(fd, off_t(mappedSize)) == 0,
              let memory = mmap(nil, mappedSize, PROT_READ, MAP_SHARED, fd, 0), memory != MAP_FAILED else {
            throw NSError(domain: "Pluck", code: 1)
        }
        mapped = memory
    }

    deinit {
        munmap(mapped, mappedSize)
        try? FileManager.default.removeItem(at: buffer)
    }

    func close() {}

    private static func openClip(_ url: URL) throws -> [String: Any] {
        if !librariesSet {
            pluck_raw_set_libraries(libraries.path)
            librariesSet = true
        }
        let reply = try ask(["op": "open", "path": url.path])
        openPath = url.path
        return reply
    }

    /// One frame at 1/scale of the size, ready to watch (Rec.709).
    func frame(_ index: Int, scale: Int) throws -> CGImage {
        try Self.lock.withLock {
            if Self.openPath != url.path { _ = try Self.openClip(url) }
            let reply = try Self.ask(["op": "frame", "index": index, "scale": scale, "look": "display",
                                      "buffer": buffer.path, "size": mappedSize])
            let w = (reply["width"] as? NSNumber)?.intValue ?? 0, h = (reply["height"] as? NSNumber)?.intValue ?? 0
            guard w > 0, h > 0, w * h * 8 <= mappedSize,
                  let provider = CGDataProvider(data: Data(bytes: mapped, count: w * h * 8) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                                      space: CGColorSpace(name: CGColorSpace.itur_709)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw NSError(domain: "Pluck", code: 2)
            }
            return image
        }
    }

    /// The smallest decode that's still at least this wide.
    func scale(forWidth wanted: Double) -> Int {
        for scale in [16, 8, 4, 2] where Double(width / scale) >= wanted { return scale }
        return 1
    }

    private static func ask(_ request: [String: Any]) throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        guard let answer = pluck_raw_request(json) else { throw NSError(domain: "Pluck", code: 4) }
        defer { free(answer) }
        guard let reply = try JSONSerialization.jsonObject(with: Data(String(cString: answer).utf8)) as? [String: Any],
              (reply["ok"] as? Bool) == true else {
            let problem = (try? JSONSerialization.jsonObject(with: Data(String(cString: answer).utf8)) as? [String: Any])?["problem"] as? String
            throw NSError(domain: "Pluck", code: 3, userInfo: [NSLocalizedDescriptionKey: problem ?? "The decoder couldn’t read this."])
        }
        return reply
    }

    /// The clip's file: an .RDC folder's first R3D, or the file itself.
    static func clipFile(_ url: URL) -> URL {
        guard url.hasDirectoryPath else { return url }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "r3d" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first ?? url
    }
}
