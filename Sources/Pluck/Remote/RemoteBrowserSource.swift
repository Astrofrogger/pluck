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
    /// The folder Ask for Files is being set up for (its share path).
    var asking: String?
    /// The folder whose People sheet is open (its share path).
    var people: String?
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
            olderHost = entries.contains { $0.clip == nil }
            return entries.map { entry in
                let (info, raw, clipFolder) = Self.info(entry)
                let relative = path.isEmpty ? entry.name : path + "/" + entry.name
                if raw { rawClips.insert(relative) } else { rawClips.remove(relative) }
                if clipFolder { clipFolders.insert(relative) } else { clipFolders.remove(relative) }
                return (url(relative, folder: info.isFolder), info)
            }
        } catch {
            problem = error.localizedDescription
            return []
        }
    }

    /// How the host's entry shows, whether it's a clip only pluck-raw reads (played from a proxy the host makes),
    /// and whether it's a clip folder. A clip folder (a RED .RDC) is one clip with its files' size, also from a host
    /// from before clips, which sent it as an empty file (Pluck's RED types make it a package) or a folder.
    nonisolated static func info(_ entry: OfficeRenderClient.RemoteEntry) -> (info: FinderInfo, raw: Bool, clipFolder: Bool) {
        let kind = (entry.name as NSString).pathExtension.lowercased(), type = UTType(filenameExtension: kind)
        let raw = entry.raw ?? (kind == "rdc" || OffloadClips.rawKinds.contains(kind))
        let clip = entry.clip ?? (entry.isVideo || raw)
        let folder = entry.folder && !clip, clipFolder = raw && !OffloadClips.rawKinds.contains(kind)
        return (FinderInfo(name: entry.name, isFolder: folder, isClip: clip, isPhoto: !folder && !clip && type?.conforms(to: .image) == true,
                           size: folder || (clipFolder && entry.size == 0) ? nil : entry.size, modified: entry.modified,
                           kind: folder ? String(localized: "Folder") : clipFolder ? String(localized: "Clip") : type?.localizedDescription ?? "",
                           tags: []), raw, clipFolder)
    }

    /// Share paths of the raw clips listed (RED, Blackmagic RAW, clip folders), and of the clip folders among them.
    @ObservationIgnored private(set) var rawClips: Set<String> = []
    @ObservationIgnored private var clipFolders: Set<String> = []
    /// The host's last listing came from a Pluck from before clips: it can't make previews of raw ones.
    private(set) var olderHost = false

    func open(_ url: URL) {
        guard RemoteHooks.player != nil, !(olderHost && rawClips.contains(relative(url))) else { return }
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
            try await RemotePullManager.shared.pullOriginal(share: share, path: path, into: destination, clipFolder: clipFolders.contains(path))
            notice = String(localized: "Fetching the original.")
        } catch {
            notice = Self.refusal(error)
        }
    }

    /// Files chosen here go straight into that folder of the share (RemoteSendInto), never over a file there.
    func sendHere(_ path: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Send")
        panel.message = String(localized: "Files to put in “\((path as NSString).lastPathComponent.isEmpty ? share.name : (path as NSString).lastPathComponent)” at the office.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let files = panel.urls, share = share.id
        Task {
            do {
                let names = try await RemoteSendInto.send(files, share: share, path: path) { [weak self] name, fraction in
                    self?.notice = String(localized: "Sending \(name): \(Int(fraction * 100)) %")
                }
                notice = names.count == 1 ? String(localized: "Sent as \(names[0]).") : String(localized: "\(names.count) files sent.")
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Pins the folder (RemotePins): its proxies or originals kept here.
    func keep(_ path: String, originals: Bool) async {
        do {
            try await RemotePins.shared.pin(share: share, path: path, originals: originals)
            notice = String(localized: "Kept on this Mac. See Kept on This Mac.")
        } catch {
            notice = Self.refusal(error)
        }
    }

    // MARK: - Favourites (per host Mac)

    /// Folders starred on the host, kept per host Mac: lines of "share id<tab>path".
    static var favouritesKey: String { "editAnywhereFavourites-" + (OfficeRenderClient.shared.office?.device.uuidString ?? "") }

    static func favourites(_ stored: String) -> [(share: String, path: String)] {
        stored.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// `stored` with that folder added, or taken out if it was there.
    static func toggled(_ stored: String, share: String, path: String) -> String {
        var list = favourites(stored)
        if let index = list.firstIndex(where: { $0.share == share && $0.path == path }) { list.remove(at: index) } else { list.append((share, path)) }
        return list.map { $0.share + "\t" + $0.path }.joined(separator: "\n")
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
    @AppStorage private var favourites: String

    init(source: RemoteFinderSource, paths: [String], clip: Bool) {
        self.source = source
        self.paths = paths
        self.clip = clip
        _favourites = AppStorage(wrappedValue: "", RemoteFinderSource.favouritesKey)
    }

    var body: some View {
        if clip, RemoteHooks.player != nil, let path = paths.first, !(source.olderHost && source.rawClips.contains(path)) {
            Button("Play") { source.playing = path }
            Divider()
        }
        Button("Make Proxies") { Task { await source.makeProxies(paths, format: proxyFormat) } }
        if RemoteProxyMode.of(source.share.id, in: streamed) == .download {
            Button("Pull Proxies") { source.pull(paths, format: proxyFormat) }
        }
        if paths.count == 1, !clip, let path = paths.first {
            Button("Keep Proxied") { Task { await source.keepProxied(path, format: proxyFormat) } }
            Button("Send Files Here…") { source.sendHere(path) }
                .help("Files from this Mac go into this folder at the office (needs Editor there)")
            Button("People…") { source.people = path }
                .help("Who may do what here (Admins)")
            Button("Ask for Files…") { source.asking = path }
                .help("A link anyone can upload to: the files land in this folder on the NAS (needs Editor there)")
            Menu("Keep on This Mac") {
                Button("Proxies") { Task { await source.keep(path, originals: false) } }
                Button("Originals") { Task { await source.keep(path, originals: true) } }
            }
            .help("Pluck keeps this folder up to date on this Mac, so you can edit offline")
            if !path.isEmpty {
                let starred = RemoteFinderSource.favourites(favourites).contains { $0.share == source.share.id && $0.path == path }
                Divider()
                Button(starred ? "Remove from Favourites" : "Add to Favourites") {
                    favourites = RemoteFinderSource.toggled(favourites, share: source.share.id, path: path)
                }
            }
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

    /// `start`: the folder in the share to begin in ("": its top), also where Columns start.
    init(source: RemoteFinderSource, start: String = "") {
        self.source = source
        let url = source.url(start, folder: true)
        _pane = State(initialValue: FinderPane(url: url, base: url, source: source))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FinderPaneView(pane: pane)
                    .coordinateSpace(name: "finder")
                if let item = chosen {
                    Divider()
                    RemotePreview(source: source, item: item, path: source.relative(item.url))
                        .finderResizable("finderPreviewWidth.editAnywhere", width: 260, range: 200...560, edge: .leading)
                        .id(item.url)
                }
            }
            Divider()
            actions
        }
        .onAppear { FinderThumbnails.shared.register(source) }
        .onDisappear { FinderThumbnails.shared.unregister(source) }
        .sheet(isPresented: Binding(get: { source.people != nil }, set: { if !$0 { source.people = nil } })) {
            if let path = source.people {
                RemoteAccessSheet(share: source.share.id, path: path, folderName: path.isEmpty ? source.share.name : (path as NSString).lastPathComponent)
            }
        }
        .sheet(isPresented: Binding(get: { source.asking != nil }, set: { if !$0 { source.asking = nil } })) {
            if let path = source.asking {
                RemoteAskFilesSheet(folderName: path.isEmpty ? source.share.name : (path as NSString).lastPathComponent) { name, password, days, bytes, types in
                    let answer = try await OfficeRenderClient.shared.ask("askFiles", ["share": source.share.id, "path": path, "name": name, "password": password,
                                                                                      "days": days, "maxBytes": bytes, "types": types], timeout: 120)
                    guard let url = answer["url"] as? String else { throw OfficeLink.Failure.garbled }
                    return url
                }
            }
        }
        .sheet(isPresented: Binding(get: { source.playing != nil }, set: { if !$0 { source.playing = nil } })) {
            if let path = source.playing, let player = RemoteHooks.player {
                VStack(spacing: 0) {
                    player(source.share.id, path, source.rawClips.contains(path)).frame(minWidth: 720, minHeight: 420)
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
            if olderRaw {
                Text("Update Pluck on the host Mac to preview raw clips.")
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if item.isClip, RemoteHooks.player != nil, !olderRaw {
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

    /// A raw clip on a host that can't make its preview.
    private var olderRaw: Bool { source.olderHost && source.rawClips.contains(path) }

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
