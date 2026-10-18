import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One subtitle in the Editor: when it shows and what it says (editable).
struct SubtitleCue: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
}

/// How the Editor's subtitles look and where they sit on the picture: the font and its weight,
/// size, colour, an outline, a shadow, a box behind them, italics and capitals.
struct SubtitleStyle: Codable, Equatable {
    /// Size against the default (5% of the picture's height).
    var scale = 1.0
    /// The middle of the subtitle, as a share of the picture's width and height.
    var x = 0.5
    var y = 0.88
    /// RGB hex without "#".
    var color = "FFFFFF"
    /// On a box, rather than with an outline.
    var box = true
    var font = "Helvetica Neue"
    /// 400 regular, 500 medium, 700 bold, 900 heavy.
    var weight = 700
    /// The outline's width and the shadow's distance, in pixels of a 1080-line picture.
    var outline = 2.0
    var outlineColor = "000000"
    var shadow = 1.5
    var boxColor = "000000"
    /// How solid the box is (0…1).
    var boxOpacity = 0.68
    var italic = false
    var uppercase = false

    static let swatches = ["FFFFFF", "FFD60A", "FF5C6B", "30D158", "0A84FF"]

    /// Fonts that read well as subtitles, those this Mac has.
    static var fonts: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["Helvetica Neue", "SF Pro", "Avenir Next", "Futura", "Gill Sans", "Arial", "Arial Rounded MT Bold",
                "Verdana", "Georgia", "Didot", "Menlo", "Impact", "Marker Felt"].filter(installed.contains)
    }

    static let weights: [(value: Int, title: LocalizedStringKey)] = [(400, "Regular"), (500, "Medium"), (700, "Bold"), (900, "Heavy")]

    init() {}

    init(color: String) { self.color = color }

    // Older saved subtitles don't have every setting: those keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitleStyle()
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? d.x
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        box = try c.decodeIfPresent(Bool.self, forKey: .box) ?? d.box
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? d.font
        weight = try c.decodeIfPresent(Int.self, forKey: .weight) ?? d.weight
        outline = try c.decodeIfPresent(Double.self, forKey: .outline) ?? d.outline
        outlineColor = try c.decodeIfPresent(String.self, forKey: .outlineColor) ?? d.outlineColor
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? d.shadow
        boxColor = try c.decodeIfPresent(String.self, forKey: .boxColor) ?? d.boxColor
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? d.italic
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase
    }

    var swiftUIColor: Color { Self.color(color) }
    var swiftUIOutline: Color { Self.color(outlineColor) }
    var swiftUIBox: Color { Self.color(boxColor) }

    static func color(_ hex: String) -> Color {
        let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// A colour as RGB hex, from a colour picker.
    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return String(format: "%02X%02X%02X", Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }

    /// A colour as subtitles files write it: &HAABBGGRR (alpha 00 is solid).
    static func assColor(_ hex: String, opacity: Double = 1) -> String {
        let value = UInt32(hex, radix: 16) ?? 0xFFFFFF
        let alpha = Int(((1 - min(max(opacity, 0), 1)) * 255).rounded())
        return String(format: "&H%02X%02X%02X%02X", alpha, value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF)
    }

    var assColor: String { Self.assColor(color) }

    /// The font size for a picture this tall.
    func fontSize(height: Double) -> Double { height * 0.05 * scale }

    var swiftUIWeight: Font.Weight {
        switch weight {
        case ..<450: .regular
        case ..<600: .medium
        case ..<800: .bold
        default: .heavy
        }
    }

    /// The words as shown: in capitals when asked for.
    func shown(_ text: String) -> String { uppercase ? text.uppercased() : text }
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
        // Outline and shadow are set for a 1080-line picture.
        let factor = Double(height) / 1080
        let italic = style.italic ? -1 : 0
        let font = style.font.replacingOccurrences(of: ",", with: " ")
        let line: String
        if style.box {
            // A box behind each line (BorderStyle 3): its colour is the outline's, its padding the outline's width.
            line = "Style: Sub,\(font),\(Int(size)),\(style.assColor),\(style.assColor),\(SubtitleStyle.assColor(style.boxColor, opacity: style.boxOpacity)),&H80000000,0,\(italic),0,0,100,100,0,0,3,\(String(format: "%.1f", size * 0.22)),\(String(format: "%.1f", style.shadow * factor)),5,0,0,0,1"
        } else {
            line = "Style: Sub,\(font),\(Int(size)),\(style.assColor),\(style.assColor),\(SubtitleStyle.assColor(style.outlineColor)),&H80000000,0,\(italic),0,0,100,100,0,0,1,\(String(format: "%.1f", style.outline * factor)),\(String(format: "%.1f", style.shadow * factor)),5,0,0,0,1"
        }
        let x = Int(style.x * Double(width)), y = Int(style.y * Double(height))
        let events = cues.map { cue in
            let text = style.shown(cue.text).replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
                .replacingOccurrences(of: "\n", with: "\\N")
            return "Dialogue: 0,\(assTime(cue.start)),\(assTime(cue.end)),Sub,,0,0,0,,{\\an5\\pos(\(x),\(y))\\b\(style.weight)}\(text)"
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

/// Saves subtitles on their own, as an .srt file (or WebVTT, when the name ends in .vtt).
@MainActor
enum SubtitleSaver {
    static func save(_ cues: [SubtitleCue], name: String) {
        guard !cues.isEmpty else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + ".srt"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.message = String(localized: "Subtitles as SRT, or WebVTT when the name ends in .vtt.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = url.pathExtension.lowercased() == "vtt" ? vtt(cues) : EditorSubtitleFiles.srt(cues)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        func time(_ t: Double) -> String {
            let ms = Int((max(t, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return "WEBVTT\n\n" + cues.map { "\(time($0.start)) --> \(time($0.end))\n\($0.text)\n" }.joined(separator: "\n")
    }
}
