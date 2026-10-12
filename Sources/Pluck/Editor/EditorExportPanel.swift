import SwiftUI

/// The Editor's export, in the inspector next to the picture, like an editing program's render
/// settings: what to export, as what (a preset, or the codec, size, frame rate and quality by
/// hand), the sound, the subtitles, and what this file exported.
struct EditorExportPanel: View {
    @Bindable var model: EditorModel
    @Environment(DownloadManager.self) private var manager
    @AppStorage("editorExportFormat") private var format = EditorExportChoice.Format.video
    @AppStorage("editorExportEach") private var each = false
    @AppStorage("editorExportBurn") private var burn = true
    @AppStorage("editorExportSRT") private var srt = false
    @AppStorage("editorRenderSettings") private var stored = ""

    private var exports: EditorExports { model.exports }

    private var settings: EditorRenderSettings {
        get { EditorRenderSettings(saved: stored) }
        nonmutating set {
            var tidied = newValue
            tidied.tidy()
            stored = tidied.saved
        }
    }

    private func bind<Value>(_ path: WritableKeyPath<EditorRenderSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: path] }, set: { value in var changed = settings; changed[keyPath: path] = value; settings = changed })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if model.isEdited {
                    SidebarSection(title: Text("What")) {
                        choice(symbol: "film", title: Text("The Edit"), detail: Text(model.timecode(model.editLength)), on: !each) { each = false }
                        choice(symbol: "square.split.2x1", title: Text("Each Part"),
                               detail: Text(verbatim: "\(model.keptParts.count)"), on: each) { each = true }
                    }
                }

                SidebarSection(title: Text("Format")) {
                    HStack(spacing: 4) {
                        ForEach(EditorExportChoice.Format.allCases.filter(isAvailable)) { item in
                            FormatChip(symbol: item.symbol, title: Text(item.title), on: resolvedFormat == item) { format = item }
                                .help(Text(item.detail))
                        }
                    }
                    .padding(.horizontal, 6)
                }

                switch resolvedFormat {
                case .video: videoSettings
                case .audio: audioOnlySettings
                default: EmptyView()
                }

                if !model.subtitles.isEmpty, model.hasVideo, resolvedFormat != .audio {
                    SidebarSection(title: Text("Subtitles")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Burn into the picture", isOn: $burn)
                                .disabled(resolvedFormat != .video)
                            Toggle("Save an .srt file", isOn: $srt)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.horizontal, 8)
                    }
                }

                footer

                if !exports.finished.isEmpty {
                    SidebarSection(title: Text("Exported")) {
                        ForEach(exports.finished, id: \.self) { file in
                            DoneLabel(text: Text(file.lastPathComponent), file: file)
                                .font(.caption)
                                .padding(.horizontal, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Settings

    private var videoSettings: some View {
        Group {
            SidebarSection(title: Text("Preset")) {
                Picker("Preset", selection: Binding(get: { settings.preset }, set: { preset in
                    if let chosen = preset.settings { settings = chosen }
                })) {
                    ForEach(EditorRenderSettings.Preset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
            }

            SidebarSection(title: Text("Video")) {
                setting("File") {
                    Picker("File", selection: bind(\.container)) {
                        ForEach(EditorRenderSettings.Container.allCases) { Text($0.title).tag($0) }
                    }
                }
                setting("Codec") {
                    Picker("Codec", selection: bind(\.codec)) {
                        ForEach(EditorRenderSettings.Codec.allCases) { Text($0.title).tag($0) }
                    }
                }
                setting("Resolution") {
                    Picker("Resolution", selection: bind(\.resolution)) {
                        ForEach(EditorRenderSettings.Resolution.allCases) { Text($0.title).tag($0) }
                    }
                }
                setting("Frame Rate") {
                    Picker("Frame Rate", selection: bind(\.frameRate)) {
                        ForEach(EditorRenderSettings.FrameRate.allCases) { Text($0.title).tag($0) }
                    }
                }
                if !settings.codec.isProRes {
                    setting("Quality") {
                        Picker("Quality", selection: bind(\.quality)) {
                            ForEach(EditorRenderSettings.Quality.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if settings.quality == .size {
                        setting("Size") {
                            HStack(spacing: 4) {
                                TextField("MB", value: bind(\.targetMB), format: .number)
                                    .frame(width: 56)
                                    .multilineTextAlignment(.trailing)
                                Text(verbatim: "MB").foregroundStyle(.secondary)
                            }
                        }
                    }
                    setting("Fast Encoding") {
                        Toggle("Fast Encoding", isOn: bind(\.hardware))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                    }
                    .help("This Mac’s own encoder: much faster, a little larger for the same quality")
                }
            }

            SidebarSection(title: Text("Audio")) {
                if settings.container == .mov {
                    setting("Codec") {
                        Picker("Codec", selection: bind(\.audioCodec)) {
                            ForEach(EditorRenderSettings.AudioCodec.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                if settings.audioCodec == .aac { bitrate }
            }
        }
    }

    private var audioOnlySettings: some View {
        SidebarSection(title: Text("Audio")) {
            setting("File") {
                Picker("File", selection: bind(\.audioFile)) {
                    ForEach(EditorRenderSettings.AudioFile.allCases) { Text($0.title).tag($0) }
                }
            }
            if settings.audioFile != .wav { bitrate }
        }
    }

    private var bitrate: some View {
        setting("Bitrate") {
            Picker("Bitrate", selection: bind(\.audioKbps)) {
                ForEach([128, 160, 192, 256, 320], id: \.self) { Text(verbatim: "\($0) kbit/s").tag($0) }
            }
        }
    }

    /// A setting's name on the left, its menu on the right.
    private func setting<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            content()
                .labelsHidden()
                .frame(maxWidth: 150, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }

    // MARK: - Export

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                exports.run(EditorExportChoice(format: resolvedFormat, each: each && model.isEdited,
                                               burn: burn && !model.subtitles.isEmpty && model.showSubtitles,
                                               srt: srt && !model.subtitles.isEmpty, settings: settings),
                            model: model, manager: manager)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(model.duration == 0 || exports.isRunning || (model.isEdited && model.keptParts.isEmpty))
            status
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var status: some View {
        if let progress = exports.progress {
            ProgressView(value: progress).controlSize(.small)
        } else if let problem = exports.problem {
            Text(problem).font(.caption).foregroundStyle(.orange)
        } else if exports.handedOver {
            Label("In the download list", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        }
    }

    /// Formats a song can't be (video, GIF) are left out.
    private func isAvailable(_ item: EditorExportChoice.Format) -> Bool {
        model.hasVideo || item == .audio || item == .original
    }

    private var resolvedFormat: EditorExportChoice.Format { isAvailable(format) ? format : .audio }

    /// What's exported, how long, and (for a render) its size: "Edit 0:01:12 · 1920×1080 · ≈ 84 MB".
    private var summary: String {
        let length = model.isEdited ? model.editLength : model.rangeEnd - model.rangeStart
        var parts = [model.isEdited ? (each ? String(localized: "Each part") : String(localized: "The edit"))
                     : model.hasRange ? String(localized: "The range") : String(localized: "The whole file"),
                     model.timecode(length)]
        if resolvedFormat == .video {
            let size = settings.outputSize(source: model.pixelSize)
            parts.append("\(Int(size.width))×\(Int(size.height))")
            let bytes = settings.estimatedBytes(source: model.pixelSize, sourceFPS: model.frameRate, length: length)
            parts.append("≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func choice(symbol: String, title: Text, detail: Text?, on: Bool, action: @escaping () -> Void) -> some View {
        SidebarRow(symbol: symbol, title: title, detail: detail, selected: on) {
            if on { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
        }
        .onTapGesture(perform: action)
    }
}

/// One of the export formats, as a small tile with a symbol.
private struct FormatChip: View {
    let symbol: String
    let title: Text
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                title.font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? Color.white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(on ? (Edition.isStudio ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.accentColor))
                          : AnyShapeStyle(Color.primary.opacity(hovering ? 0.1 : 0.05)))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What the export panel chose.
struct EditorExportChoice {
    enum Format: String, CaseIterable, Identifiable {
        case video, audio, gif, original
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .video: "Video"
            case .audio: "Audio"
            case .gif: "GIF"
            case .original: "Copy"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .video: "Rendered with the settings below."
            case .audio: "Just the sound."
            case .gif: "Short and silent, for chats."
            case .original: "The original streams, cut without rendering: fastest, same quality."
            }
        }

        var symbol: String {
            switch self {
            case .video: "film"
            case .audio: "waveform"
            case .gif: "photo.on.rectangle.angled"
            case .original: "doc.on.doc"
            }
        }

        /// Pluck's conversion, for GIFs and copies.
        var preset: Conversion.Preset { self == .gif ? .gif : .trim }
    }

    var format: Format
    var each: Bool
    var burn: Bool
    var srt: Bool
    var settings: EditorRenderSettings
}
