import SwiftUI

/// File ▸ Export Subtitles…: the open file's or project's subtitles on their own (.srt or .vtt).
/// A file without subtitles made yet gives its transcript's lines.
struct ExportSubtitlesCommand: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        Button("Export Subtitles…") {
            guard let (cues, name) = subtitles() else { NSSound.beep(); return }
            SubtitleSaver.save(cues, name: name)
        }
        .keyboardShortcut("e", modifiers: [.command, .option])
        .disabled(nav.current == nil)
    }

    private func subtitles() -> ([SubtitleCue], String)? {
        guard let tab = nav.current else { return nil }
        if let project = tab.project {
            let cues = project.project.subtitleCues
            return cues.isEmpty ? nil : (cues, project.project.name)
        }
        guard let model = tab.model else { return nil }
        let name = model.file.deletingPathExtension().lastPathComponent
        if !model.subtitles.isEmpty { return (model.subtitles, name) }
        guard let transcript = TranscriptStore.find(forFile: model.file.path) else { return nil }
        let cues = transcript.cues(maxCharacters: 84, maxDuration: 6).map {
            SubtitleCue(start: $0.start, end: $0.end, text: Transcript.twoLines(Glossary.correct($0.text, terms: Glossary.shared.terms)))
        }
        return cues.isEmpty ? nil : (cues, name)
    }
}
