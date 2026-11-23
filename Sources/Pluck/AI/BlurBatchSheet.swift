import SwiftUI

/// Privacy Blur on several videos: every face found in each is blurred (picking people to keep
/// sharp is for one video at a time), one video after the other.
struct BlurBatchSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    @AppStorage("blurStyle") private var style: PrivacyBlur.Style = .blur
    @AppStorage("blurText") private var blurText = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "eye.slash", title: Text("Privacy Blur"), subtitle: Text(AIStudio.Batch(items).title))

            Form {
                Picker("Style", selection: $style) {
                    ForEach(PrivacyBlur.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $blurText) {
                    Text("Also blur text")
                    Text("Licence plates, name tags, screens and signs. Titles and captions in the video are blurred too.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Every face in each video is blurred. To keep someone sharp, blur one video at a time. Check the results before sharing them.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Blur") {
                    for item in items { studio.privacyBlurAll(item, blurText: blurText, style: style) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 500)
    }
}

extension AIStudio {
    /// Finds the faces in its turn, then queues the blur itself (the same job one video gets).
    func privacyBlurAll(_ item: DownloadItem, blurText: Bool, style: PrivacyBlur.Style) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Looking for faces…")
            item.aiProgress = 0
            do {
                let analysis = try await Self.offMain {
                    try await PrivacyBlur.analyze(file) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    }
                }
                guard !analysis.faces.isEmpty || blurText else { throw ToolFailure(message: String(localized: "No faces found in this video.")) }
                item.aiStatus = nil
                item.aiProgress = nil
                privacyBlur(item, analysis: analysis, keepSharp: [], blurText: blurText, style: style)
            } catch {
                failJob(item, error)
            }
        }
    }
}
