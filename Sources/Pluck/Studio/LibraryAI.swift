import SwiftUI

/// AI actions on Library items: they're listed as local files, then handed to the same sheets
/// and queue the download list uses (AIStudio).
struct LibraryAIRun: Identifiable {
    enum Action { case subtitles, cleanup, tighten, enhance, background, blur, shorts }
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
    private var videos: [URL] { files.filter(Converting.isVideo) }

    var body: some View {
        let ai = AppDelegate.shared?.ai
        if !media.isEmpty, ai != nil, LocalAI.canTranscribe || AudioCleanup.isSupported || !videos.isEmpty {
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
                if !videos.isEmpty {
                    Divider()
                    if LocalAI.canTranscribe {
                        Button("Make Shorts…") { run = LibraryAIRun(action: .shorts, items: videoItems()) }
                    }
                    if Enhance.isSupported {
                        Button("Upscale & Smooth…") { run = LibraryAIRun(action: .enhance, items: videoItems()) }
                    }
                    Button("New Background…") { run = LibraryAIRun(action: .background, items: videoItems()) }
                    Button("Privacy Blur…") { run = LibraryAIRun(action: .blur, items: videoItems()) }
                }
            }
        }
    }

    private func items() -> [DownloadItem] { AppDelegate.shared?.manager.addLocalFiles(media) ?? [] }
    private func videoItems() -> [DownloadItem] { AppDelegate.shared?.manager.addLocalFiles(videos) ?? [] }
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
                case .enhance: EnhanceSheet(items: run.items).environment(ai)
                case .background: BackgroundSheet(items: run.items).environment(ai)
                case .blur:
                    if run.items.count == 1 { PrivacyBlurSheet(item: run.items[0]).environment(ai) } else { BlurBatchSheet(items: run.items).environment(ai) }
                case .shorts: ShortsSheet(items: run.items).environment(ai)
                }
            }
        }
    }
}
