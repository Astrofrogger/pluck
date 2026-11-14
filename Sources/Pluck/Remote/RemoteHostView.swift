import AppKit
import SwiftUI

/// The host's shares in Edit Anywhere → Share this Mac → Footage: each folder online or offline with
/// its free space, Find Shots on or off, the folders kept proxied, and the proxies being made.
struct RemoteSharesList: View {
    @State private var archive = OfficeArchive.shared
    @State private var shares = RemoteShares.shared
    @State private var jobs = RemoteProxyJobs.shared
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(archive.folders, id: \.self) { folder in row(folder) }
            ForEach(jobs.requests.filter { !$0.watch && $0.state != .ready }.suffix(6)) { request in requestRow(request) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
            }
        }
        .task(id: archive.folders) {
            while !Task.isCancelled {
                await shares.sync()
                for folder in archive.folders { _ = await shares.state(folder) }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    // MARK: Rows

    private func row(_ folder: URL) -> some View {
        let state = shares.states[folder.path], share = shares.share(folder)
        let online = state?.online ?? true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StudioTile(symbol: online ? "externaldrive.connected.to.line.below" : "externaldrive.badge.xmark",
                           colour: online ? Design.Studio.textQuiet : Design.Studio.warn, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.lastPathComponent).font(Design.Studio.body).lineLimit(1)
                    Group {
                        if let state, !state.online {
                            Text("Offline").foregroundStyle(Design.Studio.warn)
                        } else if let state, state.total > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: state.free, countStyle: .file)) free")
                        } else {
                            Text(verbatim: folder.deletingLastPathComponent().path)
                        }
                    }
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1).truncationMode(.middle)
                }
                .help(share?.volume.map { "\($0) – \(folder.path)" } ?? folder.path)
                Spacer(minLength: 0)
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    .accessibilityHidden(true)
                Toggle("Find Shots", isOn: Binding(get: { shares.searchable(folder) }, set: { shares.setSearch($0, for: folder) }))
                    .toggleStyle(StudioSwitchStyle())
                    .help("Find Shots: paired Macs search this folder by what’s in the picture")
                Menu {
                    Menu("Keep Proxied") {
                        ForEach([OfficeProxies.Format.light, .prores]) { format in
                            Button(format.label + "…") { addWatch(in: folder, format: format) }
                        }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    Divider()
                    Button("Stop Sharing", role: .destructive) { archive.remove(folder) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                        .frame(width: 28, height: 28).contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More")
            }
            ForEach(share?.watch ?? [], id: \.self) { watch in watchRow(watch, in: folder) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }

    /// A folder kept proxied: its name, format, and how far its proxies are.
    private func watchRow(_ watch: RemoteShares.Watch, in folder: URL) -> some View {
        let request = jobs.requests.first { $0.watch && $0.share == OfficeProxies.id(folder) && $0.paths == [watch.path] && $0.format == watch.format }
        return HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).frame(width: 32)
                .accessibilityHidden(true)
            Text(verbatim: watch.path.isEmpty ? folder.lastPathComponent : watch.path).font(Design.Studio.hint).lineLimit(1).truncationMode(.middle)
            StudioChip(text: Text(verbatim: watch.format == .light ? "H.265" : "ProRes"))
            Spacer(minLength: 0)
            if let request { progress(request).frame(maxWidth: 160) }
            Button { shares.removeWatch(watch, in: folder) } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Design.Studio.textQuiet).frame(width: 20, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop keeping it proxied")
            .help("Stop keeping it proxied")
        }
        .help("New files here get proxies by themselves")
    }

    /// Proxies a paired Mac asked for.
    private func requestRow(_ request: RemoteProxyJobs.Request) -> some View {
        HStack(spacing: 12) {
            StudioTile(symbol: "laptopcomputer", colour: Design.Studio.textQuiet, size: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: request.paths.map { $0.isEmpty ? "/" : ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(Design.Studio.body).lineLimit(1).truncationMode(.middle)
                progress(request)
            }
            if request.state == .failed {
                Button { jobs.remove(request.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Design.Studio.textQuiet).frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .studioBox()
    }

    @ViewBuilder
    private func progress(_ request: RemoteProxyJobs.Request) -> some View {
        switch request.state {
        case .queued:
            StudioChip(text: Text("Waiting"))
        case .making:
            let share = request.total > 0 ? (Double(request.done) + jobs.progress) / Double(request.total) : 0
            VStack(alignment: .leading, spacing: 3) {
                StudioProgress(share: share)
                Text("\(request.done) of \(request.total)").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
        case .ready:
            StudioChip(text: Text("\(request.done) ready"), symbol: "checkmark", colour: Design.Studio.good, tinted: true)
        case .failed:
            StudioChip(text: Text(request.failed.isEmpty ? "Failed" : "\(request.failed.count) failed"), symbol: "exclamationmark.triangle",
                       colour: Design.Studio.bad, tinted: true)
                .help(request.problem ?? request.failed.joined(separator: "\n"))
        }
    }

    // MARK: Actions

    private func addWatch(in folder: URL, format: OfficeProxies.Format) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder
        panel.prompt = String(localized: "Keep Proxied")
        panel.message = String(localized: "New files in this folder get proxies by themselves.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let base = RemoteEditHost.realPath(folder.path) ?? folder.path, chosen = RemoteEditHost.realPath(url.path) ?? url.path
        guard chosen == base || chosen.hasPrefix(base + "/") else {
            problem = String(localized: "Choose a folder inside “\(folder.lastPathComponent)”.")
            return
        }
        problem = nil
        shares.addWatch(String(chosen.dropFirst(base.count + 1)), format: format, in: folder)
    }
}

/// What a paired Mac may do on this Mac (Paired Macs): browse, fetch proxies, fetch originals, render.
struct RemoteRightsMenu: View {
    let device: OfficeRenderServer.Device

    private static let rights: [(WritableKeyPath<OfficeRenderServer.Device.Rights, Bool>, LocalizedStringKey, String)] = [
        (\.browse, "Browse Footage", "folder"), (\.proxies, "Fetch Proxies", "square.stack.3d.down.right"),
        (\.originals, "Fetch Originals", "film"), (\.render, "Render", "play.rectangle"),
    ]

    var body: some View {
        Menu {
            ForEach(Self.rights.indices, id: \.self) { index in
                let (key, title, _) = Self.rights[index]
                Toggle(title, isOn: Binding(get: { device.allowed[keyPath: key] }, set: { value in
                    var rights = device.allowed
                    rights[keyPath: key] = value
                    OfficeRenderServer.shared.setRights(rights, for: device.id)
                }))
            }
        } label: {
            HStack(spacing: 6) {
                ForEach(Self.rights.indices, id: \.self) { index in
                    let (key, _, symbol) = Self.rights[index]
                    Image(systemName: symbol).font(.system(size: 11))
                        .foregroundStyle(device.allowed[keyPath: key] ? Design.Studio.text : Design.Studio.textFaint)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .frame(height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("What this Mac may do here")
        .help("What this Mac may do here")
    }
}
