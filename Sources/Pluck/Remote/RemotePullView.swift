import AppKit
import SwiftUI

/// Edit Anywhere's Files on the remote Mac: the host's shares in the Library's Finder views, the
/// host's state (offline, share offline, rendering), and per share how its proxies come here:
/// downloaded (the pulls) or streamed (the network connection), this Mac's choice. A host from before remote
/// editing (no `status`) gets the older proxies pane, `legacy`.
struct RemoteFilesPane<Legacy: View>: View {
    @ViewBuilder var legacy: Legacy
    @State private var host = HostState.checking
    @State private var shares: [OfficeRenderClient.RemoteShare] = []
    @State private var busy = false
    @State private var sources: [String: RemoteFinderSource] = [:]
    @AppStorage("editAnywhereBrowseShare") private var shareID = ""
    @State private var pulls = RemotePullManager.shared
    @State private var mode = RemoteProxyMode.download

    enum HostState: Equatable { case checking, current, older, offline(String) }

    var body: some View {
        Group {
            if host == .older {
                legacy
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    content
                    if host == .current, let share, share.online { delivery(share) }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private var share: OfficeRenderClient.RemoteShare? { shares.first { $0.id == shareID } ?? shares.first }

    private var header: some View {
        HStack(spacing: 8) {
            Text("On the host Mac").font(Design.Studio.sectionTitle)
            switch host {
            case .checking: PlumSpinner()
            case .offline: StudioChip(text: Text("Host offline"), symbol: "wifi.slash", colour: Design.Studio.warn, tinted: true)
            default: StudioChip(text: Text("Online"), colour: Design.Studio.good, tinted: true)
            }
            if busy { StudioChip(text: Text("Rendering"), symbol: "film").help("The host Mac is rendering: browsing and pulls are slower meanwhile") }
            Spacer(minLength: 8)
            if let share {
                if !share.online { StudioChip(text: Text("Share offline"), symbol: "externaldrive.badge.xmark", colour: Design.Studio.warn, tinted: true) }
                else if share.totalBytes > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: share.freeBytes, countStyle: .file)) free")
                        .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                }
                if shares.count > 1 {
                    Menu {
                        Picker("Share", selection: Binding(get: { share.id }, set: { shareID = $0 })) {
                            ForEach(shares) { Text(verbatim: $0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(share.name, systemImage: "externaldrive").font(Design.Studio.body)
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                }
            }
        }
    }

    /// Download or Stream for this share, and what that mode is doing.
    private func delivery(_ share: OfficeRenderClient.RemoteShare) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StudioSegmented(options: [(RemoteProxyMode.download, LocalizedStringKey("Download")), (.stream, LocalizedStringKey("Stream"))],
                                selection: Binding(get: { mode }, set: { mode = $0; RemoteProxyMode.set($0, for: share.id) }))
                    .fixedSize()
                    .help("How this Mac works from this share’s proxies")
                Spacer(minLength: 8)
                if mode == .download {
                    Button {
                        pulls.chooseRoot(for: share)
                    } label: {
                        Label(pulls.roots[share.id].map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(localized: "Choose…"), systemImage: "internaldrive")
                            .font(Design.Studio.body)
                    }
                    .buttonStyle(.plain)
                    .help("Where downloaded proxies go on this Mac")
                }
            }
            switch mode {
            case .download: RemotePullsList(share: share.id)
            case .stream: RemoteNetworkPane(share: share.id)
            }
        }
        .onChange(of: share.id, initial: true) { mode = RemoteProxyMode.of(share.id) }
    }

    @ViewBuilder private var content: some View {
        switch host {
        case .offline(let problem):
            StudioEmptyState(symbol: "wifi.slash", title: "\(OfficeRenderClient.shared.office?.name ?? String(localized: "The host Mac")) is offline. Pluck connects when it’s back",
                             line: LocalizedStringKey(problem), button: "Try Again") { Task { await check() } }
                .frame(height: 220)
                .studioBox()
        case .checking:
            EmptyView()
        default:
            if let share {
                if share.online {
                    RemoteBrowserView(source: source(for: share)).id(share.id).frame(height: 460)
                } else {
                    StudioEmptyState(symbol: "externaldrive.badge.xmark", title: "This share is offline",
                                     line: "Its drive or NAS isn’t reachable from the host Mac right now.")
                        .frame(height: 220)
                        .studioBox()
                }
            } else {
                StudioEmptyState(symbol: "folder", title: "No folders shared yet", line: "On the host Mac, add one in Edit Anywhere → Share this Mac.")
                    .frame(height: 220)
                    .studioBox()
            }
        }
    }

    private func source(for share: OfficeRenderClient.RemoteShare) -> RemoteFinderSource {
        if let source = sources[share.id] { return source }
        let source = RemoteFinderSource(share: share)
        // (Made while the view is drawn: kept from the next turn.)
        Task { sources[share.id] = source }
        return source
    }

    private func check() async {
        do {
            let status = try await OfficeRenderClient.shared.status()
            shares = status.shares
            busy = status.busy
            host = .current
        } catch OfficeLink.Failure.office {
            // A host from before remote editing doesn't know `status`.
            host = .older
        } catch {
            host = .offline(error.localizedDescription)
        }
    }
}

/// The pulls: how far each is, the speed limit, and pause, show, stop and Link in Resolve.
private struct RemotePullsList: View {
    let share: String
    @State private var pulls = RemotePullManager.shared
    @State private var mode = RemoteProxyMode.download
    @State private var linking: String?
    @State private var problem: String?

    private static let limits: [(Int, LocalizedStringKey)] = [(0, "No limit"), (1 << 20, "1 MB/s"), (5 << 20, "5 MB/s"), (10 << 20, "10 MB/s"), (25 << 20, "25 MB/s")]

    private var jobs: [RemotePullManager.Job] { pulls.jobs.filter { $0.share == share } }

    var body: some View {
        if jobs.isEmpty {
            Text("Choose Pull Proxies on files above.").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(summary).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
                    Spacer(minLength: 8)
                    Picker("Speed", selection: Bindable(pulls).limit) {
                        ForEach(Self.limits, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .fixedSize()
                    .help("The most the pulls take of this Mac’s connection")
                }
                if let problem { Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.body).foregroundStyle(Design.Studio.bad) }
                ForEach(jobs) { row($0) }
            }
        }
    }

    private var summary: String {
        let states = jobs.compactMap { pulls.progress[$0.id] }
        let total = states.reduce(Int64(0)) { $0 + $1.totalBytes }, here = states.reduce(Int64(0)) { $0 + min($1.bytesHere, $1.totalBytes) }
        guard total > 0 else { return "" }
        var text = String(localized: "\(ByteCountFormatter.string(fromByteCount: here, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        if let left = pulls.timeLeft { text += " · " + String(localized: "\(Format.duration(left)) left") }
        return text
    }

    private func row(_ job: RemotePullManager.Job) -> some View {
        let state = pulls.progress[job.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StudioTile(symbol: job.format == .original ? "film" : "arrow.down.circle", colour: Design.Studio.textQuiet, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title(job)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(job, state)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
                Spacer(minLength: 8)
                if state?.finished == true, job.originals == nil, let link = RemoteHooks.linkInResolve {
                    if linking == job.id { PlumSpinner() } else {
                        Button("Link in Resolve") {
                            linking = job.id
                            Task {
                                do { try await link(URL(fileURLWithPath: job.destination, isDirectory: true)); problem = nil } catch { problem = error.localizedDescription }
                                linking = nil
                            }
                        }
                        .buttonStyle(StudioFlatButtonStyle())
                    }
                }
                if state?.finished != true {
                    rowButton(job.paused ? "play.fill" : "pause.fill", job.paused ? "Resume" : "Pause") { pulls.setPaused(job, !job.paused) }
                }
                rowButton("folder", "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.destination)])
                }
                rowButton("xmark", "Stop Pulling") { pulls.remove(job) }
            }
            if let state, state.totalBytes > 0, !state.finished {
                StudioProgress(share: Double(state.bytesHere) / Double(state.totalBytes))
            }
            if let problem = state?.problem ?? state?.failed.values.first {
                Text(problem).font(Design.Studio.hint).foregroundStyle(Design.Studio.warn).lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .studioBox()
    }

    private func rowButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet).frame(width: 28, height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func title(_ job: RemotePullManager.Job) -> String {
        let place = job.paths.count == 1 ? (job.paths[0].isEmpty ? job.shareName : (job.paths[0] as NSString).lastPathComponent)
            : String(localized: "\(job.paths.count) items in \(job.shareName)")
        return place
    }

    private func subtitle(_ job: RemotePullManager.Job, _ state: RemotePullManager.Progress?) -> String {
        guard let state else { return job.paused ? String(localized: "Paused") : String(localized: "Waiting") }
        if state.finished { return String(localized: "All \(state.files) here") }
        var parts = [String(localized: "\(state.filesHere) of \(state.files) here")]
        if job.paused { parts.insert(String(localized: "Paused"), at: 0) }
        if state.waiting { parts.append(String(localized: "the host Mac is still making some")) }
        if !state.failed.isEmpty { parts.append(String(localized: "\(state.failed.count) to try again")) }
        return parts.joined(separator: " · ")
    }
}
