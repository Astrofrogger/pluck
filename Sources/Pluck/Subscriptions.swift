import Foundation
import Observation

/// A channel, playlist or podcast Pluck keeps an eye on: new uploads are downloaded by themselves,
/// in the format and folder chosen when subscribing.
struct Subscription: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The link as it was given (a channel, a playlist, a podcast feed).
    var url: String
    var title: String
    var owner: String?
    var options: DownloadOptions
    var folder: String
    /// Everything already in it when last looked, by the site's id: never downloaded again.
    var seen: [String] = []
    /// What it downloaded, by link identity, so the Library can show them together.
    var downloaded: [String] = []
    var added = Date.now
    var lastChecked: Date?
    var lastFound: Date?
    var paused = false
    /// Why the last look didn't work, if it didn't.
    var problem: String?
}

@MainActor
@Observable
final class Subscriptions {
    static let shared = Subscriptions()
    /// How often each one is looked at while Pluck runs.
    static let interval: TimeInterval = 3600
    /// How many of the newest uploads are looked at each time.
    static let depth = 30

    private(set) var list: [Subscription] = []
    private(set) var checking: Set<Subscription.ID> = []
    @ObservationIgnored weak var manager: DownloadManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var running: Task<Void, Never>?

    /// Test copies (screenshot mode) keep their own list, so a test never touches the real one.
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ScreenshotMode.scene == nil ? "Pluck/subscriptions.json" : "Pluck/subscriptions-test.json")
    }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? decoder.decode([Subscription].self, from: data) {
            list = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Starts looking for new uploads: soon after launch, then every few minutes for the ones due.
    /// Test copies (screenshot mode) never download anything by themselves.
    func start(manager: DownloadManager) {
        self.manager = manager
        guard ScreenshotMode.scene == nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in Subscriptions.shared.checkDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            checkDue()
        }
    }

    func checkDue() {
        let due = list.filter { !$0.paused && Date.now.timeIntervalSince($0.lastChecked ?? .distantPast) >= Self.interval - 60 }
        check(due.map(\.id))
    }

    /// Looks at these, one after another.
    func check(_ ids: [Subscription.ID]) {
        let waiting = ids.filter { !checking.contains($0) }
        guard !waiting.isEmpty else { return }
        checking.formUnion(waiting)
        let previous = running
        running = Task {
            await previous?.value
            for id in waiting {
                await look(at: id)
                checking.remove(id)
            }
        }
    }

    // MARK: - Subscribing

    /// Subscribes to a link, given what's in it now (those are never downloaded by the subscription;
    /// the ones picked to download now are queued by the picker and counted as its downloads).
    func subscribe(url: String, title: String, owner: String?, options: DownloadOptions, folder: String,
                   known: [String], downloadingNow: [String]) {
        if let index = list.firstIndex(where: { Links.identity($0.url) == Links.identity(url) }) {
            list[index].paused = false
            list[index].options = options
            list[index].seen = Array(Set(list[index].seen + known))
            list[index].downloaded += downloadingNow.map(Links.identity)
        } else {
            var subscription = Subscription(url: url, title: title, owner: owner, options: options, folder: folder)
            subscription.seen = known
            subscription.downloaded = downloadingNow.map(Links.identity)
            subscription.lastChecked = .now
            list.append(subscription)
        }
        save()
    }

    func remove(_ id: Subscription.ID) {
        list.removeAll { $0.id == id }
        save()
    }

    func setPaused(_ paused: Bool, for id: Subscription.ID) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].paused = paused
        save()
    }

    func setOptions(_ options: DownloadOptions, for id: Subscription.ID) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].options = options
        save()
    }

    /// A subscription end to end, in a test copy: lists the link, subscribes as if everything but
    /// the newest upload was there before, looks for new ones (the newest is downloaded into
    /// `folder`), then looks again (nothing new). What happens goes to `log`.
    func selfTest(link: String, folder: String, log: URL) async {
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        }
        guard let manager else { note("no manager"); return }
        list.removeAll()
        guard let data = await manager.listing(Self.listingURL(link), limit: Self.depth), let found = Self.uploads(in: data) else {
            note("listing failed: \(Self.listingURL(link))")
            return
        }
        note("listed \(found.count) from \(Self.listingURL(link)); newest \(found.first?.id ?? "-")")
        var options = DownloadOptions.current
        options.kind = .video
        options.resolution = .p360
        if Self.isFeed(link) { options = .podcast }
        subscribe(url: link, title: "Test", owner: nil, options: options, folder: folder,
                  known: found.dropFirst().map(\.id), downloadingNow: [])
        guard let id = list.first?.id else { return }
        await look(at: id)
        note("first look queued \(list[0].downloaded)")
        let key = list[0].downloaded.first ?? ""
        for _ in 0..<900 {
            if let item = manager.items.first(where: { Links.identity($0.url) == key }), !item.isActive, item.state != .queued {
                note("download \(item.state) \(item.fileURL?.path ?? item.errorMessage ?? "")")
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await look(at: id)
        note("second look: \(list[0].downloaded.count) downloaded in all, problem \(list[0].problem ?? "none")")
        try? await Task.sleep(for: .seconds(3))
        let shown = LibraryStore.shared.entries.filter { $0.source.map { list[0].downloaded.contains(Links.identity($0)) } ?? false }
        note("in the Library: \(shown.map(\.title))")
        note("done")
    }

    // MARK: - Looking for new uploads

    /// What to list for a link: a YouTube channel's uploads (its Videos tab, not Shorts or lives).
    nonisolated static func listingURL(_ link: String) -> String {
        guard isChannel(link), var components = URLComponents(string: link) else { return link }
        let parts = components.path.split(separator: "/")
        // /@name, /channel/ID, /c/name, /user/name without a tab after it.
        let base = parts.first?.hasPrefix("@") == true ? 1 : 2
        if parts.count <= base {
            components.path = "/" + parts.joined(separator: "/") + "/videos"
        }
        components.query = nil
        return components.string ?? link
    }

    /// A YouTube channel link (as opposed to a playlist or a video).
    nonisolated static func isChannel(_ link: String) -> Bool {
        guard let url = URL(string: link), let host = url.host?.lowercased(), host.hasSuffix("youtube.com") else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/")
    }

    /// A podcast or other RSS/Atom feed.
    nonisolated static func isFeed(_ link: String) -> Bool {
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        return host.hasPrefix("feeds.") || path.hasSuffix(".rss") || path.hasSuffix(".xml") || path.hasSuffix("/feed")
            || path.hasSuffix("/rss") || path.hasSuffix("/feed.xml") || host.hasSuffix("anchor.fm") && path.contains("/rss")
    }

    /// A channel listing's title ("Name - Videos") without the tab.
    nonisolated static func cleanTitle(_ title: String) -> String {
        for suffix in [" - Videos", " - Uploads", " - Home"] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }

    private func look(at id: Subscription.ID) async {
        guard let manager, let subscription = list.first(where: { $0.id == id }) else { return }
        let data = await manager.listing(Self.listingURL(subscription.url), limit: Self.depth)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].lastChecked = .now
        guard let data, let found = Self.uploads(in: data) else {
            list[index].problem = String(localized: "Couldn’t look at it just now. Pluck tries again later.")
            save()
            return
        }
        list[index].problem = nil
        let seen = Set(list[index].seen)
        // Oldest first, so the newest ends up at the top of the download list.
        let fresh = found.filter { !seen.contains($0.id) }.reversed()
        for upload in fresh {
            list[index].seen.append(upload.id)
            guard !manager.isQueuedOrDownloaded(upload.url, isAudio: list[index].options.isAudio) else { continue }
            if Self.isFeed(list[index].url) {
                manager.addListed(upload.url, title: upload.title, show: upload.show, options: list[index].options, folder: list[index].folder)
            } else {
                manager.add([upload.url], options: list[index].options, folder: list[index].folder)
            }
            list[index].downloaded.append(Links.identity(upload.url))
            list[index].lastFound = .now
        }
        // The newest few thousand are enough to know what's new.
        if list[index].seen.count > 3000 { list[index].seen.removeFirst(list[index].seen.count - 3000) }
        save()
    }

    /// The uploads in a flat listing, leaving out streams that haven't finished (they're picked up
    /// once they're a normal video) and private or removed ones.
    nonisolated static func uploads(in data: Data) -> [(id: String, url: String, title: String?, show: String?)]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["entries"] as? [[String: Any]] else { return nil }
        let show = (json["title"] as? String).map(cleanTitle)
        return raw.compactMap { entry in
            guard let url = (entry["url"] as? String) ?? (entry["webpage_url"] as? String) else { return nil }
            let title = entry["title"] as? String ?? ""
            if ["[Private video]", "[Deleted video]"].contains(title) { return nil }
            if let live = entry["live_status"] as? String, ["is_upcoming", "is_live", "post_live"].contains(live) { return nil }
            return ((entry["id"] as? String) ?? episodeID(url) ?? url, url, title.isEmpty ? nil : title, show)
        }
    }

    /// A podcast episode's own id (its GUID), which yt-dlp tucks into the link it lists, so a
    /// feed that changes its tracking links doesn't look like all-new episodes.
    nonisolated static func episodeID(_ url: String) -> String? {
        guard let fragment = URLComponents(string: url)?.fragment, fragment.hasPrefix("__youtubedl_smuggle="),
              let json = String(fragment.dropFirst("__youtubedl_smuggle=".count)).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["force_videoid"] as? String
    }
}
