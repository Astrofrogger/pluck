import SwiftUI

/// All format settings, bound to user defaults so the menu and Settings stay in sync.
struct FormatSettings: DynamicProperty {
    @AppStorage(Prefs.kind) var kind: MediaKind = .video
    @AppStorage(Prefs.resolution) var resolution: Resolution = .best
    @AppStorage(Prefs.codec) var codec: VideoCodec = .compatible
    @AppStorage(Prefs.container) var container: VideoContainer = .mp4
    @AppStorage(Prefs.prefer60fps) var prefer60fps = false
    @AppStorage(Prefs.audioFormat) var audioFormat: AudioFormat = .m4a
    @AppStorage(Prefs.audioBitrate) var audioBitrate: AudioBitrate = .best
    @AppStorage(Prefs.splitChapters) var splitChapters = false

    var options: DownloadOptions {
        DownloadOptions(kind: kind, resolution: resolution, codec: codec, container: container,
                        prefer60fps: prefer60fps, audioFormat: audioFormat, audioBitrate: audioBitrate)
    }

    /// Selecting a resolution switches to video; selecting an audio format switches to audio.
    var videoSelection: Binding<Resolution?> {
        Binding(get: { kind == .video ? resolution : nil },
                set: { if let r = $0 { kind = .video; resolution = r } })
    }

    var audioSelection: Binding<AudioFormat?> {
        Binding(get: { kind == .audio ? audioFormat : nil },
                set: { if let f = $0 { kind = .audio; audioFormat = f } })
    }
}

struct FormatMenu: View {
    /// In the main window's bar: drawn as a bar control (see `Design`), the same height and
    /// glass as the link field and buttons next to it.
    var inBar = false
    private var format = FormatSettings()
    @Environment(\.openPluckSettings) private var openSettings

    var body: some View {
        Menu {
            Picker("Video", selection: format.videoSelection) {
                ForEach(Resolution.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.inline)

            Picker("Audio Only", selection: format.audioSelection) {
                ForEach(AudioFormat.allCases) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.inline)

            Divider()

            Menu {
                Picker("Codec", selection: format.$codec) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .disabled(format.container == .webm)
                Picker("Container", selection: format.$container) {
                    ForEach(VideoContainer.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Prefer 60 fps", isOn: format.$prefer60fps)
            } label: {
                Label("Video Options", systemImage: "film")
            }

            Menu {
                Picker("Bitrate", selection: format.$audioBitrate) {
                    ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Audio Quality", systemImage: "waveform")
            }
            .disabled(!format.audioFormat.supportsBitrate)

            Divider()
            Toggle(isOn: format.$splitChapters) {
                Label("Split into Chapters", systemImage: "list.number")
            }
            .help("Videos with chapters, like DJ mixes and full albums, are saved as one file per chapter")

            Divider()
            Button("More Settings…") { openSettings() }
        } label: {
            if inBar {
                HStack(spacing: 6) {
                    Image(systemName: format.options.symbol)
                        .font(.system(size: Design.Size.icon - 2, weight: .medium))
                    Text(format.options.label)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(Design.Typography.control)
                .foregroundStyle(.primary)
                .barControl()
            } else {
                Label(format.options.label, systemImage: format.options.symbol)
                    .frame(minWidth: 64)
                    .contentTransition(.numericText())
            }
        }
        .menuStyle(.button)
        .modifier(BarMenuLook(inBar: inBar))
        .fixedSize()
        .help("Output format: \(format.options.longLabel)")
    }
}

/// The menu's look: plain (the label draws itself as a bar control) in the bar, the system's
/// button with its indicator elsewhere.
private struct BarMenuLook: ViewModifier {
    let inBar: Bool

    func body(content: Content) -> some View {
        if inBar {
            content.buttonStyle(.plain).menuIndicator(.hidden)
        } else {
            content.menuIndicator(.visible)
        }
    }
}
