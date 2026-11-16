import SwiftUI

/// Deliver › "Set Up Server…": a main server or a backup (of a main one), on TrueNAS or Proxmox, each opening its own setup sheet.
struct DeliverServerChooser: View {
    enum Choice: String, Identifiable { case truenas, proxmox, other; var id: String { rawValue } }
    enum Role: Hashable { case main, backup }
    @Environment(\.dismiss) private var dismiss
    @State private var open: Choice?
    @State var role = Role.main

    /// A backup needs a main host to invite it.
    private var main: Deliver.Host? { ReviewPublish.shared.hosts.first { $0.kind == .nas && $0.role != "backup" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Server").font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
            HStack(spacing: 10) {
                StudioSegmented(options: [(Role.main, LocalizedStringKey("Main server")), (.backup, LocalizedStringKey("Backup"))], selection: $role)
                    .fixedSize().disabled(main == nil)
                if main == nil { Text("A backup needs a main server first.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet) }
            }
            HStack(spacing: 12) {
                option(.truenas, title: "TrueNAS", symbol: "externaldrive.connected.to.line.below",
                       line: role == .main ? "Paste an API key; Pluck installs and pairs it." : "Paste an API key; Pluck installs it as a backup.")
                option(.proxmox, title: "Proxmox", symbol: "server.rack",
                       line: role == .main ? "Paste one command into the Proxmox shell, then the line it prints." : "Paste one command into the Proxmox shell; it pairs by itself.")
            }
            .disabled(role == .backup && main == nil)
            HStack {
                Button("Other NAS…") { open = .other }.buttonStyle(.link).font(Design.Studio.hint)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle())
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .background(Design.Studio.panel)
        .sheet(item: $open, onDismiss: { dismiss() }) { choice in
            switch choice {
            case .other: ReviewNASGuideSheet()
            case .truenas, .proxmox:
                if role == .backup, let main { DeliverBackupSheet(main: main, kind: choice == .truenas ? .truenas : .proxmox) }
                else if choice == .truenas { ReviewTrueNASSetupSheet() }
                else { DeliverProxmoxMainSheet() }
            }
        }
    }

    private func option(_ choice: Choice, title: LocalizedStringKey, symbol: String, line: LocalizedStringKey) -> some View {
        Button { open = choice } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Design.Studio.text).frame(height: 26)
                Text(title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                Text(line).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .studioBox(outline: Design.Studio.line)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
