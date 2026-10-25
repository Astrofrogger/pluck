import SwiftUI

/// File ▸ Quick Export: the open project, with the last-used export settings, to the download folder.
struct QuickExportCommand: View {
    @State private var nav = StudioNavigator.shared
    let manager: DownloadManager

    var body: some View {
        Button("Quick Export") {
            guard let model = nav.current?.project else { NSSound.beep(); return }
            quickExport(model, manager: manager)
        }
        .keyboardShortcut("e", modifiers: [.control, .command])
        .disabled(nav.current?.project?.project.clips.isEmpty != false)
    }
}

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

/// Edit ▸ Copy and Paste Settings, for the Photo page. The keys (⌘C, ⇧⌘C, ⌘V, ⇧⌘V, ⌥⌘V) are
/// handled by the page itself, so Copy and Paste keep working in text fields.
struct PhotoSettingsCommands: View {
    @State private var nav = StudioNavigator.shared

    var body: some View {
        Divider()
        Group {
        Button("Copy Settings") { PhotoPasteboard.perform?(.copy) }
        Button("Copy Settings…") { PhotoPasteboard.perform?(.copyChoosing) }
        Button("Paste Settings") { PhotoPasteboard.perform?(.paste) }
        Button("Paste Settings…") { PhotoPasteboard.perform?(.pasteChoosing) }
        Button("Paste Previous Settings") { PhotoPasteboard.perform?(.pastePrevious) }
        }
        .disabled(nav.page != .photo)
    }
}
