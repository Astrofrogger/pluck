import AppKit
import SwiftUI

/// Host: whether paired Macs may stream the proxies (Pluck's own drive, no File Sharing involved).
struct RemoteNetworkHostView: View {
    @AppStorage(RemoteNetworkHost.streamKey) private var allowed = true

    // (What Editors save on the drive replaces a file only after the old one is kept in .pluck-versions; deletes go to
    // .pluck-trash. Both are kept: Pluck never deletes on the owner's storage.)
    var body: some View { streaming }

    private var streaming: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Streaming").font(Design.Studio.sectionTitle)
                Text("Paired Macs can edit straight from the proxies, nothing downloaded.")
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("Streaming", isOn: $allowed).toggleStyle(StudioSwitchStyle())
        }
    }
}

/// Remote: one share's proxies streamed from the host through Pluck's drive, and linked in Resolve from there.
struct RemoteNetworkPane: View {
    let share: String
    /// Switches this share to Download and pulls its proxies (offered when the link is too slow to stream them).
    var download: (() -> Void)?
    @State private var network = RemoteNetwork.shared
    @State private var problem: String?
    @State private var linking: String?
    @AppStorage(RemoteDriveBlocks.capKey) private var cacheGB = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.body).foregroundStyle(Design.Studio.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            RemoteDriveWritesView(share: share, mounted: network.state(share).isMounted, hostWrites: network.hostWrites)
        }
        .task(id: share) { await network.refresh() }
    }

    private var row: some View {
        let state = network.state(share)
        return HStack(spacing: 12) {
            StudioTile(symbol: "network", colour: state.isMounted ? Design.Studio.good : Design.Studio.textQuiet).accessibilityHidden(true)
            status(state).font(Design.Studio.hint).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let download, network.tooSlow(share) != nil {
                Button("Download Instead", action: download).buttonStyle(StudioFlatButtonStyle(prominent: true))
            }
            Menu {
                Picker("Cache", selection: $cacheGB) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("\(cacheGB) GB", systemImage: "internaldrive").font(Design.Studio.body)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .help("How much of the streamed proxies this Mac keeps")
            switch state {
            case .mounting:
                PlumSpinner()
            case .mounted(let mounted):
                Button { NSWorkspace.shared.activateFileViewerSelecting([mounted.root]) } label: {
                    Image(systemName: "folder").frame(width: 28, height: 28).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(Design.Studio.textQuiet)
                .help("Show in Finder").accessibilityLabel("Show in Finder")
                if let link = RemoteHooks.linkInResolve {
                    Button("Link in Resolve") { run { try await link(mounted.root) } }
                        .buttonStyle(StudioFlatButtonStyle(prominent: true))
                        .disabled(linking != nil)
                }
                Button("Disconnect") { Task { await network.unmount(share) } }.buttonStyle(StudioFlatButtonStyle())
            default:
                Button("Connect") { Task { _ = try? await network.mount(share) } }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(network.hostAllows == false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .studioBox()
    }

    private func status(_ state: RemoteNetwork.State) -> Text {
        switch state {
        case .mounting: return Text("Connecting…").foregroundStyle(Design.Studio.textQuiet)
        case .offline: return Text("Offline").foregroundStyle(Design.Studio.warn)
        case .failed(let message): return Text(verbatim: message).foregroundStyle(Design.Studio.warn)
        case .mounted(let mounted):
            guard let speed = mounted.speed else { return Text("Connected · measuring speed…").foregroundStyle(Design.Studio.textQuiet) }
            if let slow = network.tooSlow(share) { return Text(verbatim: slow).foregroundStyle(Design.Studio.warn) }
            let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
            switch RemoteNetwork.quality(speed: speed, format: network.streaming(share).rawValue) {
            case .smooth: return Text("Connected · \(rate)/s · smooth").foregroundStyle(Design.Studio.good)
            case .usable: return Text("Connected · \(rate)/s · usable").foregroundStyle(Design.Studio.textQuiet)
            case .slow: return Text("Connected · \(rate)/s · too slow to play smoothly").foregroundStyle(Design.Studio.warn)
            }
        case .idle:
            if network.hostAllows == false { return Text("Streaming is turned off on the host Mac").foregroundStyle(Design.Studio.textQuiet) }
            return Text("Ready to connect").foregroundStyle(Design.Studio.textQuiet)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        linking = share
        Task {
            do { try await work() } catch CocoaError.userCancelled {} catch { problem = error.localizedDescription }
            linking = nil
        }
    }
}

extension RemoteNetwork.State {
    var isMounted: Bool { if case .mounted = self { true } else { false } }
}

/// A streamed share's writing: whether this Mac can write here, what waits to upload, and what the office kept apart.
struct RemoteDriveWritesView: View {
    let share: String
    let mounted: Bool
    let hostWrites: Bool?
    @State private var writes = RemoteDriveWrites.shared

    var body: some View {
        let summary = writes.summary(share)
        VStack(alignment: .leading, spacing: 6) {
            if mounted { access(summary) }
            if summary.pending > 0 {
                let bytes = ByteCountFormatter.string(fromByteCount: summary.pendingBytes, countStyle: .file)
                line("arrow.up.circle", summary.sending.map { String(localized: "Uploading “\($0)” · \(summary.pending) waiting (\(bytes))") }
                     ?? String(localized: "\(summary.pending) waiting to upload (\(bytes))"), Design.Studio.textQuiet)
            }
            ForEach(summary.conflicts, id: \.path) { conflict in
                HStack(spacing: 8) {
                    line("doc.on.doc", String(localized: "“\((conflict.path as NSString).lastPathComponent)” changed at the office. Yours is saved as “\(conflict.name)”."),
                         Design.Studio.warn)
                    Spacer(minLength: 8)
                    Button("OK") { writes.seen(share, conflict.path) }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            ForEach(summary.refused, id: \.path) { refused in
                HStack(spacing: 8) {
                    line("exclamationmark.triangle", String(localized: "“\((refused.path as NSString).lastPathComponent)” wasn’t uploaded: \(refused.message)"),
                         Design.Studio.warn)
                    Spacer(minLength: 8)
                    Button("Try Again") { writes.retry(share, refused.path) }.buttonStyle(StudioFlatButtonStyle())
                }
            }
            if !summary.problems.isEmpty {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) { ForEach(summary.problems, id: \.self) { line("exclamationmark.triangle", $0, Design.Studio.warn) } }
                    Spacer(minLength: 8)
                    Button("OK") { writes.clearProblems(share) }.buttonStyle(StudioFlatButtonStyle())
                }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private func access(_ summary: RemoteDriveWrites.Summary) -> some View {
        if hostWrites == false || !summary.hostWrites {
            line("lock", String(localized: "Read only: the office Mac runs an older Pluck."), Design.Studio.textQuiet)
        } else if summary.top == false {
            line("lock", String(localized: "Read only: this Mac isn’t an Editor here."), Design.Studio.textQuiet)
        } else if summary.top == true {
            line("pencil", String(localized: "Can write here"), Design.Studio.good)
        }
    }

    private func line(_ symbol: String, _ text: String, _ colour: Color) -> some View {
        Label(text, systemImage: symbol).font(Design.Studio.hint).foregroundStyle(colour).fixedSize(horizontal: false, vertical: true)
    }
}
