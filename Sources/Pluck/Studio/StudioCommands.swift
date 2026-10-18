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
        return nil
    }
}
