import SwiftUI

/// AI actions on Library items: they're listed as local files, then handed to the same sheets
/// and queue the download list uses (AIStudio).
struct LibraryAIRun: Identifiable {
    enum Action { case subtitles, cleanup, tighten }
    let id = UUID()
    let action: Action
    let items: [DownloadItem]
}

/// "AI" in the Library's item menus, for one item or a selection.
struct LibraryAIMenu: View {
    /// The files that are there.
    let files: [URL]
    @Binding var run: LibraryAIRun?

    private var media: [URL] { files.filter(Converting.isMedia) }

    var body: some View {
        let ai = AppDelegate.shared?.ai
        if !media.isEmpty, ai != nil, LocalAI.canTranscribe || AudioCleanup.isSupported {
            Menu("AI") {
                if LocalAI.canTranscribe {
                    Button("Transcribe") { ai?.transcribeInBackground(items()) }
                    Button("Subtitles & Transcript…") { run = LibraryAIRun(action: .subtitles, items: items()) }
                }
                Button("Remove Silences & Fillers…") { run = LibraryAIRun(action: .tighten, items: items()) }
                if AudioCleanup.isSupported {
                    Button("Clean Up Audio…") { run = LibraryAIRun(action: .cleanup, items: items()) }
                }
                if LocalAI.canSummarize {
                    Button("Summarize") { items().forEach { ai?.summarize($0) { _ in } } }
                    Button("Add Chapters") { items().forEach { ai?.addChapters($0) { _ in } } }
                }
            }
        }
    }

    private func items() -> [DownloadItem] { AppDelegate.shared?.manager.addLocalFiles(media) ?? [] }
}

/// The sheets the Library's AI actions open (the main window's own are on Home).
struct LibraryAISheets: ViewModifier {
    @Binding var run: LibraryAIRun?

    func body(content: Content) -> some View {
        content.sheet(item: $run) { run in
            if let ai = AppDelegate.shared?.ai {
                switch run.action {
                case .subtitles:
                    if #available(macOS 26, *) { SubtitleSheet(items: run.items).environment(ai) }
                case .cleanup: AudioCleanupSheet(items: run.items).environment(ai)
                case .tighten: TightenSheet(items: run.items).environment(ai)
                }
            }
        }
    }
}
