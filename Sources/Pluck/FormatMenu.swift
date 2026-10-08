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
    private var format = FormatSettings()

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
            SettingsLink { Text("More Settings…") }
        } label: {
            Label(format.options.label, systemImage: format.options.symbol)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Output format: \(format.options.longLabel)")
    }
}
