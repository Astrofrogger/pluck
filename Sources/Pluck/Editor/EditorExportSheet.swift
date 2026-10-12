import SwiftUI

/// The Editor's export, all in view: what to export (the edit, each part, the range or the whole
/// file), as what (big tiles, each with what it's for), and the subtitles.
struct EditorExportSheet: View {
    @Bindable var model: EditorModel
    /// Starts the export with these choices.
    let start: (EditorExportChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("editorExportFormat") private var format = EditorExportChoice.Format.video
    @AppStorage("editorExportEach") private var each = false
    @AppStorage("editorExportBurn") private var burn = true
    @AppStorage("editorExportSRT") private var srt = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "square.and.arrow.up", title: Text("Export"), subtitle: Text(model.file.lastPathComponent))

            if model.isEdited {
                section(Text("What")) {
                    HStack(spacing: 8) {
                        tile(symbol: "film", title: Text("The Edit"),
                             detail: Text("The kept parts, joined: \(model.timecode(model.editLength))"), on: !each) { each = false }
                        tile(symbol: "square.split.2x1", title: Text("Each Part"),
                             detail: Text("^[\(model.keptParts.count) file](inflect: true), one per part"), on: each) { each = true }
                    }
                }
            }

            section(Text("As")) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(EditorExportChoice.Format.allCases.filter(isAvailable)) { item in
                        tile(symbol: item.symbol, title: Text(item.title), detail: Text(item.detail), on: format == item) { format = item }
                    }
                }
            }

            if !model.subtitles.isEmpty, model.hasVideo {
                section(Text("Subtitles")) {
                    Toggle("Burn them into the picture", isOn: $burn)
                        .disabled(format == .audio || format == .gif || (each && model.isEdited))
                    Toggle("Also save them as a subtitle file (.srt)", isOn: $srt)
                        .disabled(format == .audio || format == .gif)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    start(EditorExportChoice(format: resolvedFormat, each: each && model.isEdited,
                                             burn: burn && !model.subtitles.isEmpty && model.showSubtitles,
                                             srt: srt && !model.subtitles.isEmpty))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 540)
    }

    /// Formats a song can't be (video, GIF) are left out.
    private func isAvailable(_ item: EditorExportChoice.Format) -> Bool {
        model.hasVideo || item == .audio || item == .original
    }

    private var resolvedFormat: EditorExportChoice.Format { isAvailable(format) ? format : .audio }

    private var summary: String {
        if model.isEdited { return each ? String(localized: "Each kept part") : String(localized: "One file") }
        return model.hasRange ? String(localized: "The range between in and out") : String(localized: "The whole file")
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            content()
        }
    }

    private func tile(symbol: String, title: Text, detail: Text, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.callout.weight(.semibold))
                    detail.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous)
                .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// What the export sheet chose.
struct EditorExportChoice {
    enum Format: String, CaseIterable, Identifiable {
        case video, original, smaller, audio, gif
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .video: "Video (MP4)"
            case .original: "Same Quality"
            case .smaller: "Smaller File"
            case .audio: "Audio Only"
            case .gif: "GIF"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .video: "Plays everywhere, in full quality."
            case .original: "As close to the original as possible."
            case .smaller: "Up to 1080p, for sharing and mail."
            case .audio: "Just the sound."
            case .gif: "Short and silent, for chats."
            }
        }

        var symbol: String {
            switch self {
            case .video: "film"
            case .original: "checkmark.seal"
            case .smaller: "arrow.down.right.and.arrow.up.left"
            case .audio: "waveform"
            case .gif: "photo.on.rectangle.angled"
            }
        }

        /// Pluck's conversion for one part or the range (when nothing has to be joined or drawn in).
        var preset: Conversion.Preset {
            switch self {
            case .video: .mp4
            case .original: .trim
            case .smaller: .compress
            case .audio: .audio
            case .gif: .gif
            }
        }

        var quality: EditorExport.Quality {
            switch self {
            case .smaller: .small
            case .audio: .audioOnly
            default: .high
            }
        }
    }

    var format: Format
    var each: Bool
    var burn: Bool
    var srt: Bool
}
