import SwiftUI

/// Shown when videos or songs from this Mac are dropped on the window (or chosen in File →
/// Convert Files…): pick what to turn them into.
struct ConvertSheet: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.audioFormat) private var audioFormat: AudioFormat = .m4a
    @AppStorage("compressPercent") private var percent = 50
    /// nil: Automatic, 0: Original, otherwise a height.
    @State private var resolution: Int?
    @State private var details: [URL: (size: Int64, info: Converting.MediaInfo?)] = [:]
    let files: [URL]

    private var hasVideo: Bool { files.contains(where: Converting.isVideo) }

    private var heading: String {
        files.count == 1
            ? String(localized: "Convert “\(files[0].lastPathComponent)”")
            : String(localized: "Convert \(files.count) Files")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 8) {
                presetButton(.audio)
                presetButton(.mp4)
                compressCard
            }

            Picker("Audio format", selection: $audioFormat) {
                ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
            }
            .help("Used by Extract Audio")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await loadDetails() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: files.first?.path ?? ""))
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if files.count > 1 {
                    Text(files.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func presetButton(_ preset: Conversion.Preset) -> some View {
        Button {
            manager.convert(files, preset: preset)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                presetText(preset)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(ConvertCardStyle())
        .disabled(preset.needsVideo && !hasVideo)
        .accessibilityElement(children: .combine)
    }

    private func presetText(_ preset: Conversion.Preset) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: preset.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.headline)
                Text(preset.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Compress

    private var compressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            presetText(.compress)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Target size") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(percent) }, set: { percent = Int($0) }), in: 10...90, step: 5)
                            .frame(width: 200)
                            .accessibilityValue("\(percent)%")
                        Text("\(percent)%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                if hasVideo {
                    Picker("Resolution", selection: $resolution) {
                        Text("Automatic").tag(Int?.none)
                        Text(originalLabel).tag(Int?.some(0))
                        ForEach(Converting.resolutions(below: tallest), id: \.self) { Text("\($0)p").tag(Int?.some($0)) }
                    }
                    .help("Automatic keeps the resolution unless the file gets so small that a lower one looks sharper")
                }
                estimate
            }
            .padding(.leading, 46)

            HStack {
                Spacer()
                Button("Compress") {
                    manager.convert(files, preset: .compress, percent: percent, resolution: resolution)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(details.count < files.count)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.tertiary).opacity(0.8))
    }

    private var tallest: Int { files.compactMap { details[$0]?.info?.height }.max() ?? 0 }

    private var originalLabel: String {
        tallest > 0 ? String(localized: "Original (\(tallest)p)") : String(localized: "Original")
    }

    /// What each file becomes at the chosen size: the same numbers the encoder will aim for.
    private var plans: [(original: Int64, result: Int64, compression: Converting.Compression?)] {
        files.compactMap { file in
            guard let detail = details[file] else { return nil }
            guard let info = detail.info, let duration = info.duration, duration > 0 else {
                return (detail.size, detail.size * Int64(percent) / 100, nil)
            }
            let c = Converting.compression(info: info, sourceSize: detail.size, percent: percent, resolution: resolution)
            let kbps = Double((c.videoKbps ?? 0) + c.audioKbps)
            return (detail.size, Int64(kbps * 1000 / 8 * duration * 1.03), c)
        }
    }

    @ViewBuilder
    private var estimate: some View {
        if details.count < files.count {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            let plans = plans
            let original = plans.reduce(0) { $0 + $1.original }
            let result = min(plans.reduce(0) { $0 + $1.result }, original)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.bytes(original)) → about \(Format.bytes(result))")
                    .font(.headline)
                    .contentTransition(.numericText())
                Text("Saves \(Format.bytes(original - result))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if resolution == nil, let lowered = plans.compactMap({ $0.compression?.height }).max() {
                    Label("Lowered to \(lowered)p to stay sharp", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if plans.contains(where: { $0.compression?.isRough == true }) {
                    Label("At this size the quality drops noticeably", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .animation(.snappy, value: percent)
        }
    }

    private func loadDetails() async {
        for file in files {
            let size = DownloadManager.size(of: file) ?? 0
            let info = await manager.mediaInfo(for: file)
            details[file] = (size, info)
        }
    }
}

private struct ConvertCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.fill.tertiary)
                    .opacity(configuration.isPressed ? 1.6 : (hovering && isEnabled ? 1.2 : 0.8))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}
