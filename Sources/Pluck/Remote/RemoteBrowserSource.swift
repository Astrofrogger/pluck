import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One of the host Mac's shares as a Library Finder source: its folders listed by `browse`, its
/// pictures by `thumb`, read only. Files are stand-in URLs under `root` (which isn't on this Mac);
/// `relative(_:)` turns one back into the share path the host knows.
@MainActor
@Observable
final class RemoteFinderSource: FinderSource {
    let share: OfficeRenderClient.RemoteShare
    let root: URL
    /// Why the last folder couldn't be listed (nil: it could).
    var problem: String?
    /// A clip asked to play (its share path), while a player is there (RemoteHooks.player).
    var playing: String?
    /// What an action from the browser said (proxies asked for, a pull started, a refusal).
    var notice: String?
    @ObservationIgnored private var client: OfficeRenderClient { OfficeRenderClient.shared }
    /// Pictures asked for at once (each is a connection; the host takes 16 from all Macs).
    @ObservationIgnored private var fetching = 0

    init(share: OfficeRenderClient.RemoteShare) {
        self.share = share
        root = URL(fileURLWithPath: "/.pluck-remote", isDirectory: true).appendingPathComponent(share.id, isDirectory: true)
            .appendingPathComponent(share.name.isEmpty ? share.id : share.name.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// A stand-in URL's path inside the share ("" for its top).
    func relative(_ url: URL) -> String {
        let path = url.standardizedFileURL.path, base = root.standardizedFileURL.path
        return path == base ? "" : path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : ""
    }

    func url(_ relative: String, folder: Bool = false) -> URL {
        relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: folder)
    }

    func list(_ folder: URL) async -> [(URL, FinderInfo)] {
        let path = relative(folder)
        do {
            let entries = try await client.browse(share: share.id, path: path)
            problem = nil
            return entries.map { entry in
                let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
                let url = self.url(path.isEmpty ? entry.name : path + "/" + entry.name, folder: entry.folder)
                return (url, FinderInfo(name: entry.name, isFolder: entry.folder, isClip: entry.isVideo,
                                        isPhoto: !entry.folder && !entry.isVideo && type?.conforms(to: .image) == true,
                                        size: entry.folder ? nil : entry.size, modified: entry.modified,
                                        kind: entry.folder ? String(localized: "Folder") : type?.localizedDescription ?? "", tags: []))
            }
        } catch {
            problem = error.localizedDescription
            return []
        }
    }

    func open(_ url: URL) {
        guard RemoteHooks.player != nil else { return }
        playing = relative(url)
    }

    func picture(_ url: URL) async -> CGImage? {
        // shortcut: a polled cap of 4 pictures at once; a real queue if many panes browse one host.
        while fetching >= 4 { try? await Task.sleep(for: .milliseconds(60)) }
        fetching += 1
        defer { fetching -= 1 }
        guard let data = try? await client.thumb(share: share.id, path: relative(url)),
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(image, 0, nil)
    }

    func menu(_ urls: [URL]) -> AnyView {
        AnyView(RemoteFinderMenu(source: self, paths: urls.map(relative), clip: urls.count == 1 && !urls[0].hasDirectoryPath))
    }

    // MARK: - Actions from the browser

    /// The host makes proxies of these (folders: everything in them).
    func makeProxies(_ paths: [String], format: OfficeProxies.Format) async {
        do {
            try await RemotePullClient.makeProxies(share: share.id, paths: paths, format: format)
            notice = String(localized: "The host Mac is making the proxies.")
        } catch {
            notice = error.localizedDescription
        }
    }

    /// New files in this folder get proxies by themselves on the host.
    func keepProxied(_ path: String, format: OfficeProxies.Format) async {
        do {
            try await RemotePullClient.keepProxied(share: share.id, path: path, format: format, on: true)
            notice = String(localized: "New files there get proxies by themselves.")
        } catch {
            notice = error.localizedDescription
        }
    }

    /// The proxies of these fetched to this Mac (into the share's local folder, chosen once).
    func pull(_ paths: [String], format: OfficeProxies.Format) {
        guard let destination = RemotePullManager.shared.root(for: share) else { return }
        RemotePullManager.shared.pull(share: share, paths: paths, format: format, into: destination)
        notice = String(localized: "Pulling to \(destination.lastPathComponent).")
    }

    /// One clip's original fetched (needs the Originals right on the host).
    func getOriginal(_ path: String) async {
        guard let destination = RemotePullManager.shared.root(for: share) else { return }
        do {
            try await RemotePullManager.shared.pullOriginal(share: share, path: path, into: destination)
            notice = String(localized: "Fetching the original.")
        } catch {
            notice = Self.refusal(error)
        }
    }

    /// A refusal said plainly (the host's own words otherwise).
    static func refusal(_ error: Error) -> String {
        if case OfficeLink.Failure.office(let message) = error, message == String(localized: "The host Mac doesn’t allow this Mac to do that.") {
            return String(localized: "The host Mac doesn’t let this Mac fetch originals. Its owner can allow it under Share this Mac.")
        }
        return error.localizedDescription
    }
}

/// A right-click on the host's files.
private struct RemoteFinderMenu: View {
    let source: RemoteFinderSource
    let paths: [String]
    let clip: Bool
    @AppStorage("editAnywhereProxyFormat") private var format = OfficeProxies.Format.light
    @AppStorage(RemoteProxyMode.key) private var streamed = ""

    var body: some View {
        if clip, RemoteHooks.player != nil, let path = paths.first {
            Button("Play") { source.playing = path }
            Divider()
        }
        Button("Make Proxies") { Task { await source.makeProxies(paths, format: proxyFormat) } }
        if RemoteProxyMode.of(source.share.id, in: streamed) == .download {
            Button("Pull Proxies") { source.pull(paths, format: proxyFormat) }
        }
        if paths.count == 1, !clip, let path = paths.first {
            Button("Keep Proxied") { Task { await source.keepProxied(path, format: proxyFormat) } }
        }
        if clip, let path = paths.first {
            Divider()
            Button("Get Original") { Task { await source.getOriginal(path) } }
        }
    }

    /// (Originals aren't a proxy format here: Get Original is.)
    private var proxyFormat: OfficeProxies.Format { format == .original ? .light : format }
}

/// The host's shares in the Library's Finder views, with the chosen file's picture and details
/// beside it, and what to do with the selection.
struct RemoteBrowserView: View {
    let source: RemoteFinderSource
    @State private var pane: FinderPane
    @AppStorage("editAnywhereProxyFormat") private var format = OfficeProxies.Format.light
    @AppStorage(RemoteProxyMode.key) private var streamed = ""

    init(source: RemoteFinderSource) {
        self.source = source
        _pane = State(initialValue: FinderPane(url: source.root, base: source.root, source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FinderPaneView(pane: pane)
                    .coordinateSpace(name: "finder")
                if let item = chosen {
                    Divider()
                    RemotePreview(source: source, item: item, path: source.relative(item.url))
                        .frame(width: 260)
                        .id(item.url)
                }
            }
            Divider()
            actions
        }
        .clipShape(.rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
        .studioBox()
        .onAppear { FinderThumbnails.shared.register(source) }
        .onDisappear { FinderThumbnails.shared.unregister(source) }
        .sheet(isPresented: Binding(get: { source.playing != nil }, set: { if !$0 { source.playing = nil } })) {
            if let path = source.playing, let player = RemoteHooks.player {
                VStack(spacing: 0) {
                    player(source.share.id, path).frame(minWidth: 720, minHeight: 420)
                    HStack {
                        Text((path as NSString).lastPathComponent).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        Spacer()
                        Button("Done") { source.playing = nil }.buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                    }
                    .padding(12)
                }
                .background(Design.Studio.panel)
            }
        }
    }

    /// The one file selected (a folder shows nothing beside it).
    private var chosen: FinderItem? {
        guard pane.selection.count == 1 else { return nil }
        return pane.shown.first { pane.selection.contains($0.url) && !$0.isFolder }
    }

    /// What's selected, as share paths; nothing selected: the folder shown.
    private var paths: [String] {
        let picked = pane.chosen.map(source.relative)
        return picked.isEmpty ? [source.relative(pane.url)] : picked
    }

    private var proxyFormat: OfficeProxies.Format { format == .original ? .light : format }

    private var actions: some View {
        HStack(spacing: 8) {
            if let problem = source.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Design.Studio.warn).lineLimit(1)
            } else if let notice = source.notice {
                Text(notice).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Make Proxies") { Task { await source.makeProxies(paths, format: proxyFormat) } }
                .help("The host Mac makes proxies of what’s selected (or this folder)")
            Button("Keep Proxied") { Task { await source.keepProxied(source.relative(pane.url), format: proxyFormat) } }
                .help("New files in this folder get proxies by themselves")
            if RemoteProxyMode.of(source.share.id, in: streamed) == .download {
                Button("Pull Proxies") { source.pull(paths, format: proxyFormat) }
                    .help("Fetch the proxies of what’s selected (or this folder) to this Mac")
            }
        }
        .buttonStyle(StudioFlatButtonStyle())
        .font(Design.Studio.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The chosen file: its picture, what the host says it is, and play / get the original.
private struct RemotePreview: View {
    let source: RemoteFinderSource
    let item: FinderItem
    let path: String
    @State private var thumbs = FinderThumbnails.shared
    @State private var info: OfficeRenderClient.RemoteMediaInfo?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image = item.isClip ? thumbs.posters[item.url] : thumbs.pictures[item.url] {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                } else {
                    Image(nsImage: item.icon).resizable().aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .modifier(FinderWantsPicture(item: item))
            Text(item.name).font(Design.Studio.sectionTitle).lineLimit(2).truncationMode(.middle)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.0) { label, value in
                    HStack(alignment: .firstTextBaseline) {
                        Text(label).foregroundStyle(Design.Studio.textQuiet).frame(width: 74, alignment: .leading)
                        Text(verbatim: value).monospacedDigit().lineLimit(1).textSelection(.enabled)
                    }
                }
            }
            .font(Design.Studio.hint)
            HStack(spacing: 8) {
                if item.isClip, RemoteHooks.player != nil {
                    Button("Play", systemImage: "play.fill") { source.playing = path }
                }
                Button("Get Original") {
                    working = true
                    Task { await source.getOriginal(path); working = false }
                }
                .disabled(working)
                .help("Fetch this file itself (the host Mac must allow originals)")
            }
            .buttonStyle(StudioFlatButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(12)
        .foregroundStyle(Design.Studio.text)
        .task { if item.isClip { info = try? await OfficeRenderClient.shared.mediaInfo(share: source.share.id, path: path) } }
    }

    private var lines: [(String, String)] {
        var lines: [(String, String)] = []
        if let size = item.size { lines.append((String(localized: "Size"), ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        guard let info else { return lines }
        if let duration = info.duration { lines.append((String(localized: "Length"), Format.duration(duration))) }
        if let timecode = info.timecode { lines.append((String(localized: "Timecode"), timecode)) }
        if let width = info.width, let height = info.height { lines.append((String(localized: "Frame"), "\(width)×\(height)")) }
        if let fps = info.fps { lines.append((String(localized: "Rate"), String(format: fps.rounded() == fps ? "%.0f fps" : "%.3f fps", fps))) }
        if let codec = info.codec { lines.append((String(localized: "Codec"), codec)) }
        if info.audioChannels > 0 { lines.append((String(localized: "Audio"), String(localized: "\(info.audioChannels) ch"))) }
        return lines
    }
}
