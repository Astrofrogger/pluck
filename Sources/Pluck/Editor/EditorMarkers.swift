import Foundation

/// Something worth seeing on the Editor's timeline: a chapter, a cut between shots, a pause, or
/// (with local AI) a strong moment or a filler word.
struct EditorMarker: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case chapter, cut, silence, moment, filler, story

        var label: String {
            switch self {
            case .chapter: String(localized: "Chapters")
            case .cut: String(localized: "Cuts")
            case .silence: String(localized: "Pauses")
            case .moment: String(localized: "Best Moments")
            case .filler: String(localized: "Filler Words")
            case .story: String(localized: "Story")
            }
        }

        var symbol: String {
            switch self {
            case .chapter: "list.number"
            case .cut: "scissors"
            case .silence: "pause"
            case .moment: "star"
            case .filler: "text.badge.minus"
            case .story: "text.book.closed"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var start: Double
    /// For things that last: a pause, a moment.
    var end: Double?
    var title: String = ""
}

/// Finds what the Editor marks without AI: the file's own chapters, cuts between shots and pauses.
enum EditorAnalysis {
    /// The chapters stored in the file.
    static func chapters(in file: URL, ffprobe: String) async -> [EditorMarker] {
        let output = await run(ffprobe, ["-v", "error", "-show_chapters", "-of", "json", file.path])
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let chapters = json["chapters"] as? [[String: Any]] else { return [] }
        return chapters.enumerated().compactMap { index, chapter in
            guard let start = (chapter["start_time"] as? String).flatMap(Double.init) else { return nil }
            let end = (chapter["end_time"] as? String).flatMap(Double.init)
            let title = (chapter["tags"] as? [String: Any])?["title"] as? String ?? String(localized: "Chapter \(index + 1)")
            return EditorMarker(kind: .chapter, start: start, end: end, title: title)
        }
    }

    /// Where the picture cuts to another shot, from a small copy of the video.
    static func cuts(in file: URL, ffmpeg: String) async -> [EditorMarker] {
        let output = await run(ffmpeg, ["-nostdin", "-v", "error", "-i", file.path, "-an", "-sn",
                                        "-vf", "scale=240:-2,scdet=threshold=8,metadata=print:key=lavfi.scd.time:file=-",
                                        "-f", "null", "-"])
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("lavfi.scd.time="), let time = Double(line.dropFirst("lavfi.scd.time=".count)) else { return nil }
            return EditorMarker(kind: .cut, start: time)
        }
    }

    /// Pauses of at least `minimum` seconds, measured against the recording's own loudness.
    static func silences(in file: URL, ffmpeg: String, minimum: Double = 0.7) async -> [EditorMarker] {
        let output = await run(ffmpeg, ["-nostdin", "-v", "info", "-i", file.path, "-vn", "-sn",
                                        "-af", "silencedetect=noise=-40dB:d=\(minimum)", "-f", "null", "-"], errors: true)
        var markers: [EditorMarker] = []
        var start: Double?
        for line in output.split(separator: "\n") {
            if let range = line.range(of: "silence_start: ") {
                start = Double(line[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "-" })
            } else if let range = line.range(of: "silence_end: "), let begin = start,
                      let end = Double(line[range.upperBound...].prefix { $0.isNumber || $0 == "." }) {
                markers.append(EditorMarker(kind: .silence, start: max(begin, 0), end: end))
                start = nil
            }
        }
        return markers
    }

    private static func run(_ tool: String, _ arguments: [String], errors: Bool = false) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            if errors {
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
            } else {
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
            }
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
