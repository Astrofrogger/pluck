import SwiftUI

/// Search Inside Downloads: type what you remember being said, jump to that moment.
struct SearchInsideView: View {
    @Environment(AIStudio.self) private var studio
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openPluckSettings) private var openSettings
    @State private var query = ""
    @State private var hits: [TranscriptSearch.Hit] = []
    @State private var searching = false
    @State private var searched = false
    @State private var transcriptCount = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("What was said? For example “the part about lighting”", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(run)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(16)

            Divider()

            Group {
                if transcriptCount == 0 {
                    emptyIndex
                } else if hits.isEmpty {
                    ContentUnavailableView {
                        Label(searched ? "Nothing found" : "Search inside \(transcriptCount) downloads", systemImage: "waveform.and.magnifyingglass")
                    } description: {
                        Text(searched ? "Try other words, or describe what was being talked about."
                                      : "Pluck searches what was said in your transcribed videos and songs, and jumps to the moment.")
                    }
                } else {
                    List(hits) { hit in
                        Button { open(hit) } label: { row(hit) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Label(LocalAI.canSummarize ? "Local AI on this Mac helps find the right moment. Nothing is uploaded."
                                           : "Searching runs on this Mac. Nothing is uploaded.",
                      systemImage: "lock.shield")
                    .noteStyle()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .task {
            await studio.search.refresh()
            transcriptCount = studio.search.count
            focused = true
        }
    }

    private var emptyIndex: some View {
        ContentUnavailableView {
            Label("No transcripts yet", systemImage: "text.bubble")
        } description: {
            Text("Search works on transcripts, which local AI makes on this Mac. Make them for your downloads now, or turn on automatic transcripts in Settings → AI.")
        } actions: {
            Button("Transcribe My Downloads") {
                studio.transcribeInBackground(manager.items)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!LocalAI.canTranscribe)
            Button("Open AI Settings") { openSettings(.ai) }
        }
    }

    private func row(_ hit: TranscriptSearch.Hit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hit.title).font(.headline).lineLimit(1)
                Spacer()
                Label(Format.duration(hit.start), systemImage: "play.fill")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tint)
            }
            Text(highlighted(hit))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private func highlighted(_ hit: TranscriptSearch.Hit) -> AttributedString {
        var text = AttributedString(hit.text)
        for term in hit.terms {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].foregroundColor = .primary
                text[range].inlinePresentationIntent = .stronglyEmphasized
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }

    private func run() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        Task {
            hits = await studio.search.search(query)
            searched = true
            searching = false
        }
    }

    private func open(_ hit: TranscriptSearch.Hit) {
        openWindow(value: PlayerTarget(filePath: hit.filePath, transcriptID: hit.transcriptID, start: hit.start))
    }
}
