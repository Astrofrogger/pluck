import SwiftUI

/// Pluck's tools beyond downloading, in one place: the Tools button in the main window, the
/// Tools menu and the menu bar. Each opens in its own window.
enum PluckTool: String, CaseIterable, Identifiable {
    case derush, findShots, liveRecorder, deliveryCheck, logoAnimator, brandPack, musicFit, library, officeRender

    enum Group: CaseIterable {
        case editing, creating, sharing
        var title: LocalizedStringKey {
            switch self {
            case .editing: "Footage"
            case .creating: "Motion & Music"
            case .sharing: "Library & Team"
            }
        }
    }

    var id: String { rawValue }
    /// The window it opens.
    var window: String { rawValue }

    var group: Group {
        switch self {
        case .derush, .findShots, .liveRecorder, .deliveryCheck: .editing
        case .logoAnimator, .brandPack, .musicFit: .creating
        case .library, .officeRender: .sharing
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .derush: "Derush Footage"
        case .findShots: "Find Shots"
        case .liveRecorder: "Live Recorder"
        case .deliveryCheck: "Delivery Check"
        case .logoAnimator: "Logo Animator"
        case .brandPack: "Brand Pack"
        case .musicFit: "Fit Music to Length"
        case .library: "Library"
        case .officeRender: "Edit Anywhere"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .derush: "Sort a shoot into a timeline of usable takes, for DaVinci Resolve."
        case .findShots: "Search your videos for a shot by describing it."
        case .liveRecorder: "Record a stream and mark the moments as it plays."
        case .deliveryCheck: "Look over a finished export before it goes to the client."
        case .logoAnimator: "Turn a logo into an animated intro, or a vector file."
        case .brandPack: "Lower thirds, a title card and an end card in the logo’s colours."
        case .musicFit: "Make a song exactly as long as your edit."
        case .library: "Everything Pluck saved, with collections and tags."
        case .officeRender: "Render and search footage on another Mac, from anywhere."
        }
    }

    var symbol: String {
        switch self {
        case .derush: "film.stack"
        case .findShots: "photo.on.rectangle.angled"
        case .liveRecorder: "record.circle"
        case .deliveryCheck: "checkmark.seal"
        case .logoAnimator: "wand.and.stars"
        case .brandPack: "rectangle.3.group"
        case .musicFit: "music.note.list"
        case .library: "books.vertical"
        case .officeRender: "globe.europe.africa"
        }
    }

    var tint: Color {
        switch group {
        case .editing: .blue
        case .creating: .purple
        case .sharing: .teal
        }
    }
}

/// The Tools menu: in the menu bar and the menu bar panel.
struct ToolsMenuItems: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(PluckTool.Group.allCases.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            ForEach(PluckTool.allCases.filter { $0.group == group }) { tool in
                Button { open(tool) } label: { Label { Text(tool.name) } icon: { Image(systemName: tool.symbol) } }
                    .modifier(ToolShortcut(tool: tool))
            }
        }
    }

    private func open(_ tool: PluckTool) {
        openWindow(id: tool.window)
        NSApp.activate()
    }
}

private struct ToolShortcut: ViewModifier {
    let tool: PluckTool

    func body(content: Content) -> some View {
        switch tool {
        case .findShots: content.keyboardShortcut("f", modifiers: [.command, .option])
        case .library: content.keyboardShortcut("l", modifiers: [.command, .shift])
        default: content
        }
    }
}

/// The Tools panel from the main window's toolbar: every tool with a line on what it's for.
struct ToolsPanel: View {
    /// Opens the panel from elsewhere (screenshots).
    static let showNotification = Notification.Name("PluckShowTools")
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            ForEach(PluckTool.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(PluckTool.allCases.filter { $0.group == group }) { tool in
                        Button {
                            dismiss()
                            openWindow(id: tool.window)
                        } label: {
                            row(tool)
                        }
                        .buttonStyle(ToolRowStyle())
                    }
                }
            }
        }
        .padding(Design.Spacing.inset)
        .frame(width: 360)
    }

    private func row(_ tool: PluckTool) -> some View {
        HStack(spacing: Design.Spacing.controls) {
            Image(systemName: tool.symbol)
                .font(.system(size: Design.Size.icon, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tool.tint.gradient, in: .rect(cornerRadius: Design.Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name).fontWeight(.medium)
                Text(tool.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

private struct ToolRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(6)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0),
                        in: .rect(cornerRadius: Design.Radius.box))
            .onHover { hovering = $0 }
    }
}
