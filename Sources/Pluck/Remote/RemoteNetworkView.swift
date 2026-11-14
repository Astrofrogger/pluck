import AppKit
import SwiftUI

/// Host: whether paired Macs may stream the proxies (Pluck's own drive, no File Sharing involved).
struct RemoteNetworkHostView: View {
    @AppStorage(RemoteNetworkHost.streamKey) private var allowed = true

    var body: some View {
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
        }
        .task(id: share) { await network.refresh() }
    }

    private var row: some View {
        let state = network.state(share)
        return HStack(spacing: 12) {
            StudioTile(symbol: "network", colour: state.isMounted ? Design.Studio.good : Design.Studio.textQuiet).accessibilityHidden(true)
            status(state).font(Design.Studio.hint).lineLimit(2)
            Spacer(minLength: 8)
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
            let rate = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
            switch RemoteNetwork.quality(speed: speed, format: RemoteNetwork.format.rawValue) {
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
