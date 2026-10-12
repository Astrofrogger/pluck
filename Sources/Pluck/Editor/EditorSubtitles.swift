import CryptoKit
import Foundation
import SwiftUI

/// One subtitle in the Editor: when it shows and what it says (editable).
struct SubtitleCue: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

/// How the Editor's subtitles look and where they sit on the picture.
struct SubtitleStyle: Codable, Equatable {
    /// Size against the default (5% of the picture's height).
    var scale = 1.0
    /// The middle of the subtitle, as a share of the picture's width and height.
    var x = 0.5
    var y = 0.88
    /// RGB hex without "#".
    var color = "FFFFFF"
    /// On a dark box, rather than with an outline.
    var box = true

    static let swatches = ["FFFFFF", "FFD60A", "FF5C6B", "30D158", "0A84FF"]

    var swiftUIColor: Color {
        let value = UInt32(color, radix: 16) ?? 0xFFFFFF
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The colour as subtitles files write it: &HAABBGGRR.
    var assColor: String {
        let value = UInt32(color, radix: 16) ?? 0xFFFFFF
        return String(format: "&H00%02X%02X%02X", value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
    }

    /// The font size for a picture this tall.
    func fontSize(height: Double) -> Double { height * 0.05 * scale }
}

/// What the Editor keeps per file for its subtitles: the lines and their look.
private struct SavedSubtitles: Codable {
    var cues: [SubtitleCue]
    var style: SubtitleStyle
    var shown: Bool
}

extension EditorModel {
    private var subtitlesFile: URL {
        let name = SHA256.hash(data: Data(file.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Editor Subtitles/\(name).json")
    }

    /// The subtitles edited for this file before, if any.
    func loadSubtitles() {
        guard let data = try? Data(contentsOf: subtitlesFile), let saved = try? JSONDecoder().decode(SavedSubtitles.self, from: data) else { return }
        subtitles = saved.cues
        subtitleStyle = saved.style
        showSubtitles = saved.shown
    }

    func saveSubtitles() {
        let saved = SavedSubtitles(cues: subtitles, style: subtitleStyle, shown: showSubtitles)
        try? FileManager.default.createDirectory(at: subtitlesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: subtitlesFile, options: .atomic)
    }

    /// The subtitle on screen at a time.
    func subtitle(at seconds: Double) -> SubtitleCue? {
        subtitles.first { $0.start <= seconds && seconds < $0.end }
    }

    /// The subtitles for the exported edit: only what's in the kept parts, moved to where those
    /// parts land in the new file.
    func subtitlesForEdit(_ parts: [ClosedRange<Double>]) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var offset = 0.0
        for part in parts {
            for cue in subtitles where cue.end > part.lowerBound && cue.start < part.upperBound {
                let start = max(cue.start, part.lowerBound) - part.lowerBound + offset
                let end = min(cue.end, part.upperBound) - part.lowerBound + offset
                if end - start > 0.1 { result.append(SubtitleCue(start: start, end: end, text: cue.text)) }
            }
            offset += part.upperBound - part.lowerBound
        }
        return result
    }
}

/// Subtitle files for the Editor's export: burned into the picture (ASS) and alongside it (SRT).
enum EditorSubtitleFiles {
    static func ass(_ cues: [SubtitleCue], style: SubtitleStyle, width: Int, height: Int) -> String {
        let size = style.fontSize(height: Double(height))
        let line: String
        if style.box {
            // An opaque box behind each line (BorderStyle 3), dark and slightly see-through.
            line = "Style: Sub,Helvetica Neue,\(Int(size)),\(style.assColor),\(style.assColor),&H50000000,&H50000000,-1,0,0,0,100,100,0,0,3,\(String(format: "%.1f", size * 0.22)),0,5,0,0,0,1"
        } else {
            line = "Style: Sub,Helvetica Neue,\(Int(size)),\(style.assColor),\(style.assColor),&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,\(String(format: "%.1f", size / 18)),\(String(format: "%.1f", size / 24)),5,0,0,0,1"
        }
        let x = Int(style.x * Double(width)), y = Int(style.y * Double(height))
        let events = cues.map { cue in
            let text = cue.text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
                .replacingOccurrences(of: "\n", with: "\\N")
            return "Dialogue: 0,\(assTime(cue.start)),\(assTime(cue.end)),Sub,,0,0,0,,{\\an5\\pos(\(x),\(y))}\(text)"
        }
        return """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        \(line)

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events.joined(separator: "\n"))

        """
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(srtTime(cue.start)) --> \(srtTime(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func assTime(_ t: Double) -> String {
        let cs = Int((max(t, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    private static func srtTime(_ t: Double) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// A path written for an ffmpeg filter (colons and quotes escaped).
    static func filterPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:").replacingOccurrences(of: "'", with: "\\'")
    }
}
