import SwiftUI

/// Clean Up Audio: how strongly to remove noise, and how loud the result should be.
struct AudioCleanupSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    @AppStorage("cleanupStrength") private var strength: AudioCleanup.Strength = .strong
    @AppStorage("cleanupLoudness") private var loudness: AudioCleanup.Loudness = .online

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "waveform", title: Text("Clean Up Audio"), subtitle: Text(AIStudio.Batch(items).title))

            Form {
                Picker(selection: $strength) {
                    ForEach(AudioCleanup.Strength.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Noise removal")
                    Text(strength.detail)
                }
                Picker("Loudness", selection: $loudness) {
                    ForEach(AudioCleanup.Loudness.allCases) { Text($0.label).tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Made for speech: background noise, hum and wind are removed, and so is music. Runs entirely on this Mac with local AI (Apple’s voice isolation). Pluck saves a copy next to the original; the original isn’t changed.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clean Up") {
                    for item in items {
                        studio.cleanUpAudio(item, options: AudioCleanup.Options(strength: strength, loudness: loudness))
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
    }
}
