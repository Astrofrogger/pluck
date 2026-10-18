import SwiftUI

/// A new version, offered in a window of its own: what's new in it, and installing it now or
/// later.
struct UpdatePrompt: View {
    let release: AppUpdater.Release
    @Environment(AppUpdater.self) private var updater
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(Edition.name) \(release.version) is available").font(Design.Typography.sheetTitle)
                    Text("You have \(updater.currentVersion).").foregroundStyle(.secondary)
                }
            }
            let notes = AppUpdater.whatsNew(release.notes)
            if !notes.isEmpty {
                ScrollView {
                    Text(Self.formatted(notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: Design.Radius.box, style: .continuous).fill(.fill.quaternary))
            }
            if manager.activeCount > 0 {
                Label("Installing now stops ^[\(manager.activeCount) download](inflect: true).", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Button("Release Page") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.link)
                    .focusable(false)
                Spacer()
                Button("Later") {
                    updater.dismissedVersion = release.version
                    updater.prompt = nil
                    dismiss()
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                .keyboardShortcut(.cancelAction)
                Button("When I Quit") {
                    updater.prompt = nil
                    dismiss()
                    Task { await updater.installWhenQuitting() }
                }
                .buttonStyle(GlassCapsuleButtonStyle())
                .help("Downloads it now, and puts it in place when you quit Pluck: nothing stops for it")
                Button("Install & Relaunch") {
                    updater.prompt = nil
                    dismiss()
                    Task { await updater.installAndRelaunch() }
                }
                .buttonStyle(BrandButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 580)
    }

    /// The notes' Markdown (bold, links, lists) as text.
    private static func formatted(_ notes: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: notes.replacingOccurrences(of: "\n- ", with: "\n•  ").replacingOccurrences(of: "- ", with: "•  ", options: .anchored),
                                      options: options)) ?? AttributedString(notes)
    }
}

extension View {
    /// The window a new version is offered in, over this one.
    func updatePrompt(_ updater: AppUpdater) -> some View {
        sheet(isPresented: Binding(get: { updater.prompt != nil && updater.status == .available },
                                   set: { if !$0 { updater.prompt = nil } })) {
            if let release = updater.prompt { UpdatePrompt(release: release) }
        }
    }
}
