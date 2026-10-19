import CryptoKit
import SwiftUI

// MARK: - Finding clips

/// The clips in a folder and every folder in it: raw clips (an .RDC folder, a CinemaDNG folder),
/// movies and image sequences.
enum RawFolderScan {
    static let movieExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "mkv", "avi"]
    private static let sequenceExtensions: Set<String> = ["dpx", "exr", "tif", "tiff", "png", "jpg", "jpeg"]

    /// A folder that is one clip itself (Player plays it as such).
    static func isClipFolder(_ url: URL) -> Bool {
        // (A RED clip is its .RDC folder; loose R3D files elsewhere are clips of their own.)
        if url.pathExtension.lowercased() == "rdc" { return true }
        let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        if files.filter({ $0.pathExtension.lowercased() == "dng" }).count >= 2 { return true }
        // Numbered pictures of one kind, and nothing much else: an image sequence.
        let pictures = files.filter { sequenceExtensions.contains($0.pathExtension.lowercased()) && $0.lastPathComponent.contains(where: \.isNumber) }
        return pictures.count >= 10 && pictures.count * 10 >= files.count * 9
    }

    /// Every clip under `root`, in order of their folders and names.
    static func clips(in root: URL) -> [URL] {
        var found: [URL] = []
        let playable = RawFormats.extensions.subtracting(["dng"]).union(movieExtensions)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isFolder {
                if isClipFolder(url) {
                    found.append(url)
                    walker.skipDescendants()
                }
                continue
            }
            let kind = url.pathExtension.lowercased()
            guard playable.contains(kind) else { continue }
            // A RED clip's later parts (_002.R3D…) belong to its first.
            if kind == "r3d", let part = url.deletingPathExtension().lastPathComponent.split(separator: "_").last, part.count == 3,
               let number = Int(part), number > 1 { continue }
            found.append(url)
        }
        // The folder's own clips first, then each folder's in order.
        func inRoot(_ url: URL) -> Bool { url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL }
        return found.sorted {
            inRoot($0) != inRoot($1) ? inRoot($0) : $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// One folder as Finder shows it: the folders in it (not a clip themselves, nor an app or a
    /// library) and the clips right in it.
    static func contents(of root: URL) -> (folders: [URL], clips: [URL]) {
        let playable = RawFormats.extensions.subtracting(["dng"]).union(movieExtensions)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var folders: [URL] = [], clips: [URL] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if isClipFolder(url) { clips.append(url) } else if values?.isPackage != true { folders.append(url) }
                continue
            }
            let kind = url.pathExtension.lowercased()
            guard playable.contains(kind) else { continue }
            if kind == "r3d", let part = url.deletingPathExtension().lastPathComponent.split(separator: "_").last, part.count == 3,
               let number = Int(part), number > 1 { continue }
            clips.append(url)
        }
        func order(_ a: URL, _ b: URL) -> Bool { a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        return (folders.sorted(by: order), clips.sorted(by: order))
    }
}

// MARK: - Thumbnails

/// What a clip is, briefly (kept with its thumbnail).
struct RawClipSummary: Codable, Sendable {
    var frames: Int
    var fps: Double
    var width: Int
    var height: Int
    var format: String
    /// The rate it was shot at, when that's not the rate it plays at (slow or fast motion).
    var shotFps: Double?

    init(_ info: RawClipInfo) {
        frames = info.frames; fps = info.fps; width = info.width; height = info.height; format = info.format
        shotFps = info.motion == nil ? nil : info.shotFps
    }

    var motion: Double? { shotFps.map { $0 / max(fps, 1) } }
}

/// Makes clips' thumbnails and the frames shown while skimming, on a few threads. Raw clips are
/// decoded by long-running helpers that open one clip after another; the rest in Pluck itself.
final class RawThumbnailer: @unchecked Sendable {
    private let condition = NSCondition()
    private var wanted: [URL] = []
    private var skim: (url: URL, fraction: Double)?
    private var running = true
    private let poster: @Sendable (URL, RawClipSummary?, CGImage?) -> Void
    private let skimmed: @Sendable (URL, Double, CGImage) -> Void

    init(workers: Int = 3, poster: @escaping @Sendable (URL, RawClipSummary?, CGImage?) -> Void,
         skimmed: @escaping @Sendable (URL, Double, CGImage) -> Void) {
        self.poster = poster
        self.skimmed = skimmed
        for _ in 0..<workers {
            let thread = Thread { [weak self] in self?.work() }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Asks for a clip's thumbnail (the latest asked for come first: they're on screen).
    func want(_ url: URL) {
        condition.lock()
        wanted.removeAll { $0 == url }
        wanted.append(url)
        condition.broadcast()
        condition.unlock()
    }

    func forget(_ url: URL) {
        condition.lock()
        wanted.removeAll { $0 == url }
        condition.unlock()
    }

    /// The frame at a point through a clip (0…1), while the pointer skims over it.
    func skim(_ url: URL, at fraction: Double) {
        condition.lock()
        skim = (url, fraction)
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        running = false
        condition.broadcast()
        condition.unlock()
    }

    private func work() {
        let decoder = ThumbnailDecoder()
        defer { decoder.close() }
        while true {
            condition.lock()
            while running && skim == nil && wanted.isEmpty { condition.wait() }
            guard running else { condition.unlock(); return }
            if let job = skim {
                skim = nil
                condition.unlock()
                if let info = try? decoder.open(job.url), info.frames > 0 {
                    let frame = min(Int(job.fraction * Double(info.frames)), info.frames - 1)
                    if let image = try? decoder.frame(frame, info: info) { skimmed(job.url, job.fraction, image) }
                }
                continue
            }
            let url = wanted.removeLast()
            condition.unlock()
            if let cached = ThumbnailCache.load(url) {
                poster(url, cached.summary, cached.image)
                continue
            }
            do {
                let info = try decoder.open(url)
                let summary = RawClipSummary(info)
                // A moment in (the first frame is often black or a slate).
                let frame = min(info.frames / 10, Int(info.fps * 2), max(info.frames - 1, 0))
                let image = try? decoder.frame(frame, info: info)
                if let image { ThumbnailCache.save(url, summary: summary, image: image) }
                poster(url, summary, image)
            } catch {
                poster(url, nil, nil)
            }
        }
    }
}

/// One thread's decoder: a raw helper that opens clip after clip, or Pluck's own for the rest.
private final class ThumbnailDecoder {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pending = Data()
    private let buffer = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-thumb-\(UUID().uuidString).frame")
    private var mapped: UnsafeMutableRawPointer?
    private let mappedSize = 32 << 20
    private var openURL: URL?
    private var helperOpen = false
    private var source: RawSource?

    func open(_ url: URL) throws -> RawClipInfo {
        if url == openURL {
            if helperOpen, let info = helperInfo { return info }
            if let source { return source.info }
        }
        source?.close()
        source = nil
        helperOpen = false
        openURL = nil
        // Raw clips (an .RDC folder is its first R3D) go to the helper.
        let file = url.hasDirectoryPath ? firstR3D(in: url) : url
        if let file, ["r3d", "braw", "crm"].contains(file.pathExtension.lowercased()) {
            try startHelper()
            let reply = try RawHelperSource.ask(["op": "open", "path": file.path], input: input!, output: output!, pending: &pending)
            helperInfo = RawHelperSource.info(from: reply, url: file)
            helperOpen = true
            openURL = url
            return helperInfo!
        }
        let opened = try RawFormats.open(url)
        source = opened
        openURL = url
        return opened.info
    }

    private var helperInfo: RawClipInfo?

    private func firstR3D(in folder: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "r3d" }.min { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A small frame (about 400 pixels wide), 8-bit.
    func frame(_ index: Int, info: RawClipInfo) throws -> CGImage {
        var scale = 1
        while scale < 16 && info.width / (scale * 2) >= 380 { scale *= 2 }
        if helperOpen, let input, let output, let mapped {
            let reply = try RawHelperSource.ask(["op": "frame", "index": index, "scale": scale, "look": RawLook.video.helperName,
                                                 "buffer": buffer.path, "size": mappedSize, "depth": 8],
                                                input: input, output: output, pending: &pending)
            let width = (reply["width"] as? NSNumber)?.intValue ?? 0, height = (reply["height"] as? NSNumber)?.intValue ?? 0
            let eight = (reply["depth"] as? NSNumber)?.intValue == 8
            let pixel = eight ? 4 : 8
            guard width > 0, height > 0, width * height * pixel <= mappedSize,
                  let provider = CGDataProvider(data: Data(bytes: mapped, count: width * height * pixel) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: eight ? 8 : 16, bitsPerPixel: pixel * 8,
                                      bytesPerRow: width * pixel, space: CGColorSpace(name: CGColorSpace.itur_709)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: eight ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                                                                : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
            return image
        }
        guard let source else { throw RawProblem(text: String(localized: "The frame couldn’t be decoded.")) }
        return try source.displayFrame(index, scale: scale, settings: RawSettings())
    }

    private func startHelper() throws {
        if let process, process.isRunning { return }
        guard let helper = RawHelperSource.helper else { throw RawProblem(text: String(localized: "This Pluck was built without the raw decoder.")) }
        let process = Process()
        process.executableURL = helper
        let toHelper = Pipe(), fromHelper = Pipe()
        process.standardInput = toHelper
        process.standardOutput = fromHelper
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        pending = Data()
        if mapped == nil {
            FileManager.default.createFile(atPath: buffer.path, contents: nil)
            let fd = Darwin.open(buffer.path, O_RDWR)
            defer { if fd >= 0 { Darwin.close(fd) } }
            if fd >= 0, ftruncate(fd, off_t(mappedSize)) == 0, let memory = mmap(nil, mappedSize, PROT_READ, MAP_SHARED, fd, 0), memory != MAP_FAILED {
                mapped = memory
            }
        }
    }

    func close() {
        source?.close()
        if let process, process.isRunning {
            try? input?.write(contentsOf: Data("{\"op\":\"quit\"}\n".utf8))
            process.terminate()
        }
        if let mapped { munmap(mapped, mappedSize) }
        try? FileManager.default.removeItem(at: buffer)
    }
}

/// Thumbnails kept on disk (in Caches), so a folder opens at once the next time.
enum ThumbnailCache {
    private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pluck").appendingPathComponent("Player Thumbnails 2")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Named for the clip's path, size and date, so a changed clip gets a new one.
    private static func key(_ url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "2|\(url.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ url: URL) -> (summary: RawClipSummary, image: CGImage)? {
        guard let folder, let key = key(url),
              let data = try? Data(contentsOf: folder.appendingPathComponent(key + ".json")),
              let summary = try? JSONDecoder().decode(RawClipSummary.self, from: data),
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(key + ".jpg") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (summary, image)
    }

    static func save(_ url: URL, summary: RawClipSummary, image: CGImage) {
        guard let folder, let key = key(url), let data = try? JSONEncoder().encode(summary),
              let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(key + ".jpg") as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        try? data.write(to: folder.appendingPathComponent(key + ".json"))
    }
}

// MARK: - The folder

@MainActor
@Observable
final class RawBrowserClip: Identifiable {
    nonisolated let url: URL
    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }
    var poster: CGImage?
    var summary: RawClipSummary?
    var failed = false
    /// The frame under the pointer while skimming.
    var skimmed: CGImage?

    init(url: URL) { self.url = url }
}

/// A folder of footage open in Player: its clips, in groups by the folder they're in.
@MainActor
@Observable
final class RawFolder {
    let url: URL
    private(set) var groups: [(name: String, clips: [RawBrowserClip])] = []
    /// Shown a folder at a time (as Finder does): the folders in it, to go into.
    let oneLevel: Bool
    private(set) var subfolders: [URL] = []
    private(set) var scanning = true
    var search = ""
    @ObservationIgnored private var byURL: [URL: RawBrowserClip] = [:]
    @ObservationIgnored private var thumbnailer: RawThumbnailer?

    /// `clips`: these, rather than what's in the folder (the clips put in the Library one by one).
    /// `oneLevel`: only what's right in the folder, and the folders in it (else every clip
    /// under it, by folder).
    init(url: URL, clips: [URL]? = nil, oneLevel: Bool = false) {
        self.url = url
        self.oneLevel = oneLevel && clips == nil
        RawTools.prepare()
        thumbnailer = RawThumbnailer { url, summary, image in
            Task { @MainActor [weak self] in
                guard let clip = self?.byURL[url] else { return }
                clip.poster = image
                clip.summary = summary
                clip.failed = summary == nil
            }
        } skimmed: { url, _, image in
            Task { @MainActor [weak self] in self?.byURL[url]?.skimmed = image }
        }
        let root = url, single = self.oneLevel
        Task {
            let (inside, found) = await Task.detached(priority: .userInitiated) {
                single ? RawFolderScan.contents(of: root) : ([], clips ?? RawFolderScan.clips(in: root))
            }.value
            subfolders = inside
            var groups: [(name: String, clips: [RawBrowserClip])] = []
            for clipURL in found {
                let clip = RawBrowserClip(url: clipURL)
                byURL[clipURL] = clip
                let parent = clipURL.deletingLastPathComponent().path
                let name = parent == root.path ? root.lastPathComponent
                    : String(parent.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if groups.last?.name == name { groups[groups.count - 1].clips.append(clip) } else { groups.append((name, [clip])) }
            }
            self.groups = groups
            scanning = false
            // Tests: -PluckScreenshotSkim <0…1> skims the first clip there once its thumbnail is in.
            let skim = UserDefaults.standard.double(forKey: "PluckScreenshotSkim")
            if ScreenshotMode.scene == "raw", skim > 0, let first = groups.first?.clips.first {
                for _ in 0..<40 where first.poster == nil { try? await Task.sleep(for: .milliseconds(250)) }
                self.skim(first, at: skim)
            }
        }
    }

    var clipCount: Int { groups.reduce(0) { $0 + $1.clips.count } }

    /// The groups with the clips whose names match the search.
    var shown: [(name: String, clips: [RawBrowserClip])] {
        let words = search.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let clips = group.clips.filter { $0.name.localizedCaseInsensitiveContains(words) || group.name.localizedCaseInsensitiveContains(words) }
            return clips.isEmpty ? nil : (group.name, clips)
        }
    }

    /// The folders in it whose names match the search.
    var shownFolders: [URL] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? subfolders : subfolders.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(words) }
    }

    /// All clips in order (for the next and previous clip).
    var allClips: [RawBrowserClip] { groups.flatMap(\.clips) }

    func want(_ clip: RawBrowserClip) {
        guard clip.poster == nil, !clip.failed else { return }
        thumbnailer?.want(clip.url)
    }

    func forget(_ clip: RawBrowserClip) { thumbnailer?.forget(clip.url) }

    func skim(_ clip: RawBrowserClip, at fraction: Double) {
        thumbnailer?.skim(clip.url, at: min(max(fraction, 0), 1))
    }

    func endSkim(_ clip: RawBrowserClip) { clip.skimmed = nil }

    func close() {
        thumbnailer?.stop()
        thumbnailer = nil
    }
}

// MARK: - The view

/// A folder of footage: every clip as a thumbnail to skim (move the pointer across it) and open.
struct RawBrowserView: View {
    let folder: RawFolder
    let open: (URL) -> Void
    /// Browsing as Finder does: into a folder, the folders from where it began to here, and
    /// whether every clip under here shows at once.
    var enter: ((URL) -> Void)?
    var crumbs: [URL] = []
    var everyClip: Binding<Bool>?
    /// Put in the Library (indexed for Search): whether it is, and doing it.
    var inLibrary: Bool?
    var addToLibrary: (() -> Void)?
    /// Copying, checked like an offload: this folder to the other pane (when the Library is
    /// split), and what's dropped here (into this folder, or onto a folder in it).
    var copyAcross: (() -> Void)?
    var copyIn: (([URL], URL) -> Void)?
    @AppStorage("rawBrowserTileWidth") private var tileWidth = 220.0
    @State private var dropping = false

    var body: some View {
        @Bindable var folder = folder
        VStack(spacing: 0) {
            HStack(spacing: Design.Spacing.controls) {
                VStack(alignment: .leading, spacing: 0) {
                    // (The window's title names it; the Library's search field looks through it.)
                    if crumbs.count > 1, let enter { PathCrumbs(crumbs: crumbs, go: enter) }
                    // Split in two: each side names its folder (the window's title names only one).
                    else if copyAcross != nil { Text(folder.url.lastPathComponent).font(.subheadline.weight(.semibold)).lineLimit(1) }
                    if folder.scanning || folder.clipCount > 0 || folder.subfolders.isEmpty {
                        Text(folder.scanning ? String(localized: "Looking for clips…") : String(AttributedString(localized: "^[\(folder.clipCount) clip](inflect: true)").characters))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Small, so two sides fit: what each does is in its tooltip.
                HStack(spacing: 4) {
                    if let copyAcross {
                        Button("Copy to Other Side", systemImage: "arrow.right.doc.on.clipboard", action: copyAcross)
                            .help("Copy this folder to the other side, every file read back and checked")
                    }
                    if let everyClip {
                        Toggle(isOn: everyClip) { Label("Clips in Folders Inside", systemImage: "square.stack.3d.down.right") }
                            .toggleStyle(.button)
                            .help("Every clip in the folders inside, at once")
                    }
                    if let addToLibrary, inLibrary == false {
                        Button("Add to Library", systemImage: "plus.rectangle.on.folder", action: addToLibrary)
                            .help("Keep it in the sidebar and index it, so Search and Photo find what’s in it. Nothing is copied.")
                    }
                    if Resolve.isInstalled, folder.clipCount > 0 {
                        Button("Send to DaVinci", systemImage: "arrow.up.forward.app") {
                            Resolve.sendClipsAndShow(folder.shown.flatMap(\.clips).map(\.url))
                        }
                        .help("Imports the clips shown into the project open in DaVinci Resolve, each with the sound the camera recorded beside it linked to it")
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.large)
                Slider(value: $tileWidth, in: 140...420)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Thumbnail size")
            }
            .padding(.horizontal, Design.Spacing.window)
            .padding(.vertical, 10)
            Divider()
            if !folder.scanning && folder.clipCount == 0 && folder.subfolders.isEmpty {
                ContentUnavailableView("No Clips", systemImage: "film.stack",
                                       description: Text(folder.oneLevel ? "Nothing in this folder plays in Pluck." : "Nothing in this folder or the folders in it plays in Pluck."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Design.Spacing.section, pinnedViews: [.sectionHeaders]) {
                        if let enter, !folder.shownFolders.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)], spacing: 10) {
                                ForEach(folder.shownFolders, id: \.self) { inside in
                                    FolderTile(url: inside, copyIn: copyIn) { enter(inside) }
                                }
                            }
                        }
                        if folder.oneLevel {
                            // A folder at a time: its clips, under its folders, with no heading.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.6), spacing: 14)], spacing: 16) {
                                ForEach(folder.shown.flatMap(\.clips)) { clip in
                                    RawClipTile(clip: clip, folder: folder, open: open)
                                }
                            }
                        } else {
                        ForEach(folder.shown, id: \.name) { group in
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth * 1.6), spacing: 14)], spacing: 16) {
                                    ForEach(group.clips) { clip in
                                        RawClipTile(clip: clip, folder: folder, open: open)
                                    }
                                }
                            } header: {
                                Text(group.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .background(.background)
                            }
                        }
                        }
                    }
                    .padding(Design.Spacing.window)
                }
            }
        }
        // Dropped here (from the other pane, or Finder): copied into this folder.
        .dropDestination(for: URL.self) { urls, _ in
            guard let copyIn, !urls.isEmpty else { return false }
            copyIn(urls, folder.url)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping, copyIn != nil {
                RoundedRectangle(cornerRadius: Design.Radius.card).strokeBorder(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
    }
}

/// One clip: its picture (skim it by moving the pointer across), name and a line about it.
private struct RawClipTile: View {
    let clip: RawBrowserClip
    let folder: RawFolder
    let open: (URL) -> Void
    @State private var skimAt: Double?
    @State private var width = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Color.black
                if let image = clip.skimmed ?? clip.poster {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else if clip.failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                if let skimAt {
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: skimAt * width)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                if let motion = clip.summary?.motion, let shot = clip.summary?.shotFps {
                    RawMotionBadge(motion: motion, compact: true)
                        .help(Text("Shot at \(RawClipDetails.rate(shot)) fps"))
                        .padding(6)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(skimAt == nil ? 0.08 : 0.35)))
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width = max($0, 1) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let fraction = min(max(point.x / width, 0), 1)
                    skimAt = fraction
                    folder.skim(clip, at: fraction)
                case .ended:
                    skimAt = nil
                    folder.endSkim(clip)
                }
            }
            .contentShape(.rect)
            .onTapGesture { open(clip.url) }
            .draggable(clip.url)
            .contextMenu {
                Button("Open") { open(clip.url) }
                if Resolve.isInstalled {
                    Button("Send to DaVinci") { Resolve.sendClipsAndShow([clip.url]) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            }
            .help(clip.url.path)
            Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
            Text(caption).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .onAppear { folder.want(clip) }
        .onDisappear { folder.forget(clip) }
    }

    private var caption: String {
        guard let summary = clip.summary else { return " " }
        let seconds = Int(Double(summary.frames) / max(summary.fps, 1))
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let rate = summary.fps.rounded() == summary.fps ? "\(Int(summary.fps))" : summary.fps.formatted(.number.precision(.fractionLength(2)))
        let kind = ["r3d": "R3D", "braw": "BRAW", "crm": "CRM", "cdng": "DNG"][summary.format] ?? clip.url.pathExtension.uppercased()
        let shot = summary.shotFps.map { " " + String(localized: "(shot \(RawClipDetails.rate($0)))") } ?? ""
        return "\(length) · \(summary.width)×\(summary.height) · \(rate) fps\(shot) · \(kind)"
    }
}

/// A folder to go into: its Finder icon and name.
private struct FolderTile: View {
    let url: URL
    /// Dropped onto it: copied into it.
    var copyIn: (([URL], URL) -> Void)?
    let open: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.3)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.04)),
                        in: .rect(cornerRadius: Design.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .draggable(url)
        .dropDestination(for: URL.self) { urls, _ in
            guard let copyIn, !urls.isEmpty else { return false }
            copyIn(urls, url)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
        .help(url.path)
    }
}

/// Where the folder is, from where browsing began: each part goes back there.
private struct PathCrumbs: View {
    let crumbs: [URL]
    let go: (URL) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, url in
                if index > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                if index == crumbs.count - 1 {
                    Text(url.lastPathComponent).fontWeight(.semibold)
                } else {
                    Button(url.lastPathComponent) { go(url) }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .lineLimit(1)
    }
}
