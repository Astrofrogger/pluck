import AppKit
import UniformTypeIdentifiers

/// A transcript as a document to keep or share: the summary, chapters and every line with its
/// time (and speaker, when known), as plain text, Markdown or Word.
enum TranscriptExport {
    enum FileType: String, CaseIterable, Identifiable {
        case text, markdown, word
        var id: String { rawValue }

        var label: String {
            switch self {
            case .text: String(localized: "Plain Text")
            case .markdown: String(localized: "Markdown")
            case .word: String(localized: "Word Document")
            }
        }

        var type: UTType {
            switch self {
            case .text: .plainText
            case .markdown: UTType(filenameExtension: "md") ?? .plainText
            case .word: UTType(filenameExtension: "docx") ?? .data
            }
        }

        var fileExtension: String {
            switch self {
            case .text: "txt"
            case .markdown: "md"
            case .word: "docx"
            }
        }
    }

    /// One paragraph per speaker turn when speakers are known, otherwise one per line.
    private struct Paragraph {
        var time: Double
        var speaker: String?
        var text: String
    }

    private static func paragraphs(of transcript: Transcript) -> [Paragraph] {
        let cues = transcript.cues()
        guard transcript.hasSpeakers else { return cues.map { Paragraph(time: $0.start, text: $0.text) } }
        var result: [Paragraph] = []
        for cue in cues {
            let name = cue.speaker.map(transcript.speakerName)
            if let last = result.last, last.speaker == name {
                result[result.count - 1].text += " " + cue.text
            } else {
                result.append(Paragraph(time: cue.start, speaker: name, text: cue.text))
            }
        }
        return result
    }

    static func text(_ transcript: Transcript) -> String {
        var out = [transcript.title, ""]
        if let summary = transcript.summary {
            out += [String(localized: "Summary"), summary]
            for point in transcript.keyPoints ?? [] { out.append("• " + point) }
            out.append("")
        }
        if let chapters = transcript.chapters, !chapters.isEmpty {
            out.append(String(localized: "Chapters"))
            out += chapters.map { "\(Format.duration($0.start))  \($0.title)" }
            out.append("")
        }
        out.append(String(localized: "Transcript"))
        for paragraph in paragraphs(of: transcript) {
            let head = paragraph.speaker.map { "\($0) · " } ?? ""
            out.append("[\(head)\(Format.duration(paragraph.time))] \(paragraph.text)")
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func markdown(_ transcript: Transcript) -> String {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_") }
        var out = ["# " + escape(transcript.title), ""]
        if let summary = transcript.summary {
            out += ["## " + String(localized: "Summary"), "", escape(summary), ""]
            for point in transcript.keyPoints ?? [] { out.append("- " + escape(point)) }
            out.append("")
        }
        if let chapters = transcript.chapters, !chapters.isEmpty {
            out += ["## " + String(localized: "Chapters"), ""]
            out += chapters.map { "- **\(Format.duration($0.start))** \(escape($0.title))" }
            out.append("")
        }
        out += ["## " + String(localized: "Transcript"), ""]
        for paragraph in paragraphs(of: transcript) {
            let head = paragraph.speaker.map { "**\(escape($0))** · " } ?? ""
            out += ["\(head)`\(Format.duration(paragraph.time))` \(escape(paragraph.text))", ""]
        }
        return out.joined(separator: "\n")
    }

    /// A Word document (.docx), written by macOS itself.
    static func word(_ transcript: Transcript) throws -> Data {
        let document = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 12)
        func add(_ text: String, font: NSFont = body, color: NSColor = .textColor, after: CGFloat = 6) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = after
            document.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        let heading = NSFont.boldSystemFont(ofSize: 15)
        add(transcript.title, font: .boldSystemFont(ofSize: 20), after: 12)
        if let summary = transcript.summary {
            add(String(localized: "Summary"), font: heading)
            add(summary)
            for point in transcript.keyPoints ?? [] { add("• " + point, after: 2) }
            add("")
        }
        if let chapters = transcript.chapters, !chapters.isEmpty {
            add(String(localized: "Chapters"), font: heading)
            for chapter in chapters { add("\(Format.duration(chapter.start))   \(chapter.title)", after: 2) }
            add("")
        }
        add(String(localized: "Transcript"), font: heading)
        for paragraph in paragraphs(of: transcript) {
            let line = NSMutableAttributedString()
            if let speaker = paragraph.speaker {
                line.append(NSAttributedString(string: speaker + "  ", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
            }
            line.append(NSAttributedString(string: Format.duration(paragraph.time) + "  ",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                                                        .foregroundColor: NSColor.secondaryLabelColor]))
            line.append(NSAttributedString(string: paragraph.text + "\n", attributes: [.font: body]))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            document.append(line)
        }
        return try document.data(from: NSRange(location: 0, length: document.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    static func data(_ transcript: Transcript, as format: FileType) throws -> Data {
        switch format {
        case .text: Data(text(transcript).utf8)
        case .markdown: Data(markdown(transcript).utf8)
        case .word: try word(transcript)
        }
    }

    /// Asks where to save, then saves.
    @MainActor
    static func save(_ transcript: Transcript, as format: FileType, nextTo file: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.directoryURL = file.deletingLastPathComponent()
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data(transcript, as: format).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
