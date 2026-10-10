import SwiftUI
import UniformTypeIdentifiers

/// New Background: blur, a colour, a picture, or no background at all.
struct BackgroundSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("backgroundKind") private var kind: Background.Kind = .blur
    @AppStorage("backgroundColor") private var color = "1C1C1E"
    @State private var picture: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "person.and.background.dotted", title: Text("New Background"), subtitle: Text(item.title))

            Form {
                Picker(selection: $kind) {
                    ForEach(Background.Kind.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Background")
                    Text(kind.detail)
                }
                .pickerStyle(.segmented)
                if kind == .color {
                    LabeledContent("Colour") {
                        HStack(spacing: 8) {
                            ForEach(Background.swatches, id: \.self) { hex in
                                let (r, g, b) = Background.rgb(hex)
                                Button { color = hex } label: {
                                    Circle()
                                        .fill(Color(red: r, green: g, blue: b))
                                        .overlay(Circle().strokeBorder(.separator))
                                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(color == hex ? 1 : 0))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(hex)
                            }
                            ColorPicker("Other colour", selection: customColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
                if kind == .image {
                    LabeledContent("Picture") {
                        HStack {
                            if let picture {
                                Text(picture.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            }
                            Button(picture == nil ? "Choose Picture…" : "Change…", action: choosePicture)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Works best when people stand free in the picture: things in front of them, like a railing or a table edge, can be cut away too. Runs entirely on this Mac with local AI; the original isn’t changed.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace") {
                    studio.replaceBackground(item, options: Background.Options(kind: kind, color: color, image: picture))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(kind == .image && picture == nil)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 500)
    }

    private var customColor: Binding<Color> {
        Binding {
            let (r, g, b) = Background.rgb(color)
            return Color(red: r, green: g, blue: b)
        } set: { newValue in
            guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            color = String(format: "%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK { picture = panel.url }
    }
}
