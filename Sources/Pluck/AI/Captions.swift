import CoreText
import Foundation

/// Captions for shorts and burned-in subtitles, drawn in the user's caption design (see
/// `CaptionDesign`): a highlight box or colour, a size and a font.
///
/// The files are ASS subtitles rendered by ffmpeg's libass. ASS can't put a box behind one word,
/// so each word is measured with CoreText (same font) and the box is drawn as a shape.
enum Captions {
    // MARK: - Shorts (1080×1920)

    /// Captions for a short: a few words at a time, the spoken word highlighted. Lines break at
    /// pauses, sentence ends, cuts in the video (`cuts`, seconds into the short) and when they'd
    /// get wider than the frame allows.
    static func short(words: [Transcript.Word], from start: Double, cuts: [Double], design: CaptionDesign) -> String {
        let face = CaptionFonts.face(for: design)
        let size: Double = switch design.size {
        case .small: 74
        case .medium: 92
        case .large: 112
        }
        let font = measuringFont(face.postScriptName, size: size)
        let space = width(" ", font)
        let maxWidth = 900.0
        let y = 1920.0 * 0.70

        let shifted = words.map { Transcript.Word(s: $0.s - start, e: $0.e - start, t: $0.t.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.t.isEmpty && $0.e > 0 }
        var lines: [[Transcript.Word]] = []
        var current: [Transcript.Word] = []
        var currentWidth = 0.0
        for word in shifted {
            let w = width(word.t, font)
            if let last = current.last {
                let crossesCut = cuts.contains { $0 > last.e - 0.05 && $0 <= word.s + 0.05 }
                let pause = word.s - last.e > 0.45
                let sentence = [".", "?", "!", "…"].contains { last.t.hasSuffix($0) }
                let tooWide = currentWidth + space + w > maxWidth
                let tooLong = word.e - current[0].s > 2.4 || current.count >= 5
                if crossesCut || pause || sentence || tooWide || tooLong {
                    lines.append(current)
                    current = []
                    currentWidth = 0
                }
            }
            currentWidth += (current.isEmpty ? 0 : space) + w
            current.append(word)
        }
        if !current.isEmpty { lines.append(current) }

        // On a light box the spoken word turns dark; elsewhere text is white.
        let activeText: String = switch design.emphasis {
        case .box: design.isLight ? "&H00141414" : "&H00FFFFFF"
        case .color: design.assColor()
        case .plain: "&H00FFFFFF"
        }
        var events: [String] = []
        for (index, line) in lines.enumerated() {
            let lineStart = max(line[0].s - 0.05, 0)
            var lineEnd = index + 1 < lines.count ? lines[index + 1][0].s - 0.05 : (line.last!.e + 0.4)
            if let cut = cuts.first(where: { $0 > line.last!.e - 0.05 }) { lineEnd = min(lineEnd, cut) }
            lineEnd = max(lineEnd, line.last!.e)

            guard design.emphasis != .plain else {
                events.append(dialogue(layer: 1, lineStart, lineEnd, style: "Text",
                                       "{\\an5\\pos(540,\(Int(y)))\\blur1.5}" + escape(line.map(\.t).joined(separator: " "))))
                continue
            }
            let widths = line.map { width($0.t, font) }
            var x = 540 - (widths.reduce(0, +) + space * Double(line.count - 1)) / 2
            for (i, word) in line.enumerated() {
                let from = i == 0 ? lineStart : word.s
                let until = max(i + 1 < line.count ? line[i + 1].s : lineEnd, from + 0.05)
                // The line, with this word in its active colour.
                let text = line.indices.map { j in
                    j == i ? "{\\c\(activeText)&}" + escape(line[j].t) + "{\\c&H00FFFFFF&}" : escape(line[j].t)
                }.joined(separator: " ")
                events.append(dialogue(layer: 1, from, until, style: "Text", "{\\an5\\pos(540,\(Int(y)))\\blur1.5}" + text))
                if design.emphasis == .box {
                    events.append(dialogue(layer: 0, from, until, style: "Box", box(x: x, centerY: y, width: widths[i], height: size)))
                }
                x += widths[i] + space
            }
        }
        return header(width: 1080, height: 1920, styles: [
            "Style: Text,\(face.fullName),\(Int(size)),&H00FFFFFF,&H00FFFFFF,&H90000000,&H70000000,0,0,0,0,100,100,0,0,1,1.5,3,5,0,0,0,1",
            "Style: Box,\(face.fullName),\(Int(size)),\(design.assColor()),\(design.assColor()),&H00000000,&H60000000,0,0,0,0,100,100,0,0,1,0,2,7,0,0,0,1",
        ]) + events.joined(separator: "\n") + "\n"
    }

    /// A rounded rectangle behind a word, as an ASS drawing.
    private static func box(x: Double, centerY: Double, width: Double, height: Double) -> String {
        let padX = height * 0.16, padY = height * 0.08
        let w = width + padX * 2, h = height + padY * 2
        let r = h * 0.28
        let left = x - padX, top = centerY - h / 2 + height * 0.02
        let path = String(format: "m %.1f 0 l %.1f 0 b %.1f 0 %.1f 0 %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b 0 %.1f 0 %.1f 0 %.1f l 0 %.1f b 0 0 0 0 %.1f 0",
                          r, w - r, w, w, w, r, w, h - r, w, h, w, h, w - r, h, r, h, h, h, h - r, r, r)
        return "{\\an7\\pos(\(Int(left.rounded())),\(Int(top.rounded())))\\p1}" + path + "{\\p0}"
    }

    // MARK: - Subtitles burned into a regular video

    /// Classic subtitles at the bottom: plain, in a colour, or on a coloured background.
    static func subtitles(_ cues: [Transcript.Cue], width: Int, height: Int, design: CaptionDesign) -> String {
        let face = CaptionFonts.face(for: design)
        let factor: Double = switch design.size {
        case .small: 0.042
        case .medium: 0.05
        case .large: 0.06
        }
        let size = Double(height) * factor
        let style: String
        switch design.emphasis {
        case .box:
            // BorderStyle 3: an opaque box behind each line, in the colour (slightly see-through).
            let text = design.isLight ? "&H00141414" : "&H00FFFFFF"
            style = "Style: Sub,\(face.fullName),\(Int(size)),\(text),\(text),\(design.assColor(alpha: 0x22)),&H00000000,0,0,0,0,100,100,0,0,3,\(String(format: "%.1f", size * 0.22)),0,2,\(width / 10),\(width / 10),\(Int(Double(height) * 0.06)),1"
        case .color, .plain:
            let text = design.emphasis == .color ? design.assColor() : "&H00FFFFFF"
            style = "Style: Sub,\(face.fullName),\(Int(size)),\(text),\(text),&H90000000,&H70000000,0,0,0,0,100,100,0,0,1,\(String(format: "%.1f", size / 40)),\(String(format: "%.1f", size / 26)),2,\(width / 10),\(width / 10),\(Int(Double(height) * 0.06)),1"
        }
        let blur = design.emphasis == .box ? "" : "{\\blur1.2}"
        let events = cues.map { cue in
            dialogue(layer: 0, cue.start, cue.end, style: "Sub",
                     blur + escape(Transcript.twoLines(cue.text)).replacingOccurrences(of: "\n", with: "\\N"))
        }
        return header(width: width, height: height, styles: [style]) + events.joined(separator: "\n") + "\n"
    }

    /// The ffmpeg `ass` filter for a caption file, finding Pluck's added fonts as well as the Mac's.
    static func filter(_ captions: URL) -> String {
        "ass=\(FFmpegFilter.path(captions)):fontsdir=\(FFmpegFilter.path(CaptionFonts.folder))"
    }

    // MARK: - Helpers

    private static func header(width: Int, height: Int, styles: [String]) -> String {
        """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        \(styles.joined(separator: "\n"))

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
    }

    private static func dialogue(layer: Int, _ start: Double, _ end: Double, style: String, _ text: String) -> String {
        "Dialogue: \(layer),\(time(start)),\(time(end)),\(style),,0,0,0,,\(text)"
    }

    private static func time(_ t: Double) -> String {
        let cs = Int((max(t, 0) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
    }

    /// libass sizes a font by its ascent + descent; CoreText by its em. Same visual size here.
    private static func measuringFont(_ postScriptName: String, size: Double) -> CTFont {
        let probe = CTFontCreateWithName(postScriptName as CFString, 100, nil)
        let cell = (CTFontGetAscent(probe) + CTFontGetDescent(probe)) / 100
        return CTFontCreateWithName(postScriptName as CFString, size / cell, nil)
    }

    private static func width(_ text: String, _ font: CTFont) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }
}
