import SwiftUI

/// Clean Up Audio: how strongly to remove noise, and how loud the result should be.
struct AudioCleanupSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    @AppStorage("cleanupStrength") private var strength: AudioCleanup.Strength = .strong
    @AppStorage("cleanupLoudness") private var loudness: AudioCleanup.Loudness = .online

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean Up Audio").font(.title3.weight(.semibold))
                    Text(AIStudio.Batch(items).title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

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
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        .padding(24)
        .frame(width: 460)
    }
}
