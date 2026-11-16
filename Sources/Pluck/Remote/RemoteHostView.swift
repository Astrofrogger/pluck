import SwiftUI

/// The host's shares in Edit Anywhere → Share this Mac → Folders: each folder with what it's on and its
/// free space (or offline), and a Remove that asks first. Proxies and watches are under Proxies.
struct RemoteSharesList: View {
    @State private var archive = OfficeArchive.shared
    @State private var shares = RemoteShares.shared
    @State private var removing: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(archive.folders, id: \.self) { folder in row(folder) }
        }
        .task(id: archive.folders) {
            while !Task.isCancelled {
                await shares.sync()
                for folder in archive.folders { _ = await shares.state(folder) }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .alert(Text("Remove “\(removing?.lastPathComponent ?? "")”?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let removing { archive.remove(removing) }
                removing = nil
            }
        } message: {
            Text("Paired Macs can’t browse it any more. Your files stay where they are. Its proxies stay until you delete them under Proxies.")
        }
    }

    private func row(_ folder: URL) -> some View {
        let state = shares.states[folder.path], share = shares.share(folder)
        let online = state?.online ?? true
        return HStack(spacing: 12) {
            StudioTile(symbol: online ? (state?.network == true ? "externaldrive.connected.to.line.below" : "internaldrive")
                       : "externaldrive.badge.xmark",
                       colour: online ? Design.Studio.textQuiet : Design.Studio.warn, size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.lastPathComponent).font(Design.Studio.body).lineLimit(1)
                Group {
                    if let state, !state.online {
                        Text("Offline").foregroundStyle(Design.Studio.warn)
                    } else if let state, state.total > 0 {
                        Text(verbatim: [state.kind, String(localized: "\(ByteCountFormatter.string(fromByteCount: state.free, countStyle: .file)) free")]
                            .compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text(verbatim: folder.deletingLastPathComponent().path)
                    }
                }
                .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
            }
            .help(share?.volume.map { "\($0) – \(folder.path)" } ?? folder.path)
            Spacer(minLength: 0)
            Button("Remove") { removing = folder }
                .buttonStyle(StudioFlatButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }
}

/// What a paired Mac may do on this Mac (Macs → Rights): browse, fetch proxies, fetch originals, render, full trust.
struct RemoteRightsMenu: View {
    let device: OfficeRenderServer.Device

    private static let rights: [(WritableKeyPath<OfficeRenderServer.Device.Rights, Bool>, LocalizedStringKey)] = [
        (\.browse, "Browse Footage"), (\.proxies, "Fetch Proxies"), (\.originals, "Fetch Originals"), (\.render, "Render"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.rights.indices, id: \.self) { index in
                let (key, title) = Self.rights[index]
                Toggle(title, isOn: Binding(get: { device.allowed[keyPath: key] }, set: { value in
                    var rights = device.allowed
                    rights[keyPath: key] = value
                    OfficeRenderServer.shared.setRights(rights, for: device.id)
                }))
            }
            Divider()
            Toggle("Full Trust", isOn: Binding(get: { device.allowed.fullTrust }, set: { value in
                var rights = device.allowed
                rights.fullTrust = value
                OfficeRenderServer.shared.setRights(rights, for: device.id)
            }))
            .help("Renders anything this Mac sends, without checking which files it uses. Only for your own Macs.")
        } label: {
            HStack(spacing: 5) {
                if device.allowed.fullTrust { Image(systemName: "checkmark.shield").font(.system(size: 11)) }
                Text("Rights")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("What this Mac may do here")
        .help("What this Mac may do here")
    }
}
