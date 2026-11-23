import SwiftUI

/// Clean Up Audio: how strongly to remove noise, and how loud the result should be.
struct AudioCleanupSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    @AppStorage("cleanupStrength") private var strength: AudioCleanup.Strength = .strong
    @AppStorage("cleanupLoudness") private var loudness: AudioCleanup.Loudness = .online
    @AppStorage("cleanupWAV") private var wav = false
    /// One file with PCM sound: its streams, so channels can be picked.
    @State private var streams: [AudioCleanup.Stream] = []
    @State private var skipped: Set<Int> = []

    private var channelCount: Int { streams.reduce(0) { $0 + $1.channels } }
    private var hasVideo: Bool { items.contains { $0.existingFile.map(Converting.isVideo) ?? false } }

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
                if channelCount > 1 {
                    LabeledContent {
                        HStack(spacing: Design.Spacing.controls) {
                            ForEach(0..<channelCount, id: \.self) { channel in
                                Toggle(isOn: Binding(get: { !skipped.contains(channel) },
                                                     set: { if $0 { skipped.remove(channel) } else { skipped.insert(channel) } })) {
                                    Text(verbatim: "\(channel + 1)")
                                }
                                .toggleStyle(.button)
                                .accessibilityLabel(Text("Channel \(channel + 1)"))
                            }
                        }
                    } label: {
                        Text("Channels to clean")
                        Text("Each channel is cleaned on its own and kept in its place.")
                    }
                }
                if hasVideo {
                    Toggle(isOn: $wav) {
                        Text("Also save a WAV")
                        Text("For PCM sound: the clean sound beside the video, to sync in DaVinci Resolve.")
                    }
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
                        var options = AudioCleanup.Options(strength: strength, loudness: loudness)
                        options.wav = wav
                        if items.count == 1, !skipped.isEmpty { options.channels = Set(0..<channelCount).subtracting(skipped) }
                        studio.cleanUpAudio(item, options: options)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(channelCount > 1 && skipped.count == channelCount)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 460)
        .task {
            guard items.count == 1, let file = items[0].existingFile, let ffprobe = studio.toolPath("ffprobe") else { return }
            let found = await AudioCleanup.streams(file, ffprobe: ffprobe)
            if found.first?.isLossless ?? false { streams = found }
        }
    }
}
