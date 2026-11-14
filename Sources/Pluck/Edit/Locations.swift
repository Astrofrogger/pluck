import AppKit

/// The places on this Mac the Library browses, as Finder's sidebar lists them: the home
/// folder's own folders, and the drives plugged in (kept up to date as they come and go).
@MainActor
@Observable
final class Locations {
    static let shared = Locations()

    private(set) var places: [URL] = []
    /// Finder's Favorites (the home folder and its own folders), and the drives plugged in.
    private(set) var favorites: [URL] = []
    private(set) var drives: [URL] = []
    /// Each drive's symbol (card, disk, network), read when drives come and go, not on every redraw.
    private(set) var driveSymbols: [URL: String] = [:]
    /// Full Disk Access is on: no folder asks first.
    private(set) var seesEverything = false

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Locations.shared.refresh() }
            }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            // (Back from System Settings.)
            MainActor.assumeIsolated { Locations.shared.seesEverything = Locations.hasFullDiskAccess() }
        }
    }

    /// Folders the user put in Favorites, and the usual ones taken out (paths).
    private static let addedKey = "libraryFavoritesAdded", hiddenKey = "libraryFavoritesHidden"

    /// Pluck's download folder (its own place at the top of Favorites).
    static var downloadFolder: URL? {
        UserDefaults.standard.string(forKey: Prefs.downloadPath).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let own = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // (Not looked at here: a folder inside Documents or Desktop would make macOS ask.)
        let added = (UserDefaults.standard.stringArray(forKey: Self.addedKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        var seen: Set<String> = []
        let drives = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" && (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) != false }
        places = [home] + own + drives
        favorites = ([Self.downloadFolder].compactMap { $0 } + [home] + own + added)
            .filter { !hidden.contains($0.path) && seen.insert($0.standardizedFileURL.path).inserted }
        self.drives = drives
        driveSymbols = Dictionary(uniqueKeysWithValues: drives.map { ($0, Self.symbol($0)) })
        seesEverything = Self.hasFullDiskAccess()
        FootageFolders.shared.refreshPresence()
    }

    static func isDrive(_ url: URL) -> Bool { url.path.hasPrefix("/Volumes/") }

    /// A folder put in Favorites (dragged in, or chosen with +).
    func addFavorite(_ url: URL) {
        let defaults = UserDefaults.standard
        var added = defaults.stringArray(forKey: Self.addedKey) ?? []
        if !added.contains(url.path) { added.append(url.path) }
        defaults.set(added, forKey: Self.addedKey)
        defaults.set((defaults.stringArray(forKey: Self.hiddenKey) ?? []).filter { $0 != url.path }, forKey: Self.hiddenKey)
        refresh()
    }

    /// Taken out of Favorites (the folder itself stays where it is).
    func removeFavorite(_ url: URL) {
        let defaults = UserDefaults.standard
        let added = defaults.stringArray(forKey: Self.addedKey) ?? []
        if added.contains(url.path) {
            defaults.set(added.filter { $0 != url.path }, forKey: Self.addedKey)
        } else {
            defaults.set((defaults.stringArray(forKey: Self.hiddenKey) ?? []) + [url.path], forKey: Self.hiddenKey)
        }
        refresh()
    }

    /// Folders chosen to put in Favorites.
    func chooseFavorites() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addFavorite(url) }
    }

    /// A place's symbol, for the sidebar (a drive's as read when it came).
    func symbol(for url: URL) -> String { driveSymbols[url] ?? (Self.isDrive(url) ? "externaldrive" : Self.symbol(url)) }

    static func symbol(_ url: URL) -> String {
        if isDrive(url) {
            let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey])
            if values?.volumeIsLocal == false { return "network" }
            return values?.volumeIsRemovable == true ? "sdcard" : "externaldrive"
        }
        switch url.lastPathComponent {
        case "Desktop": return "menubar.dock.rectangle"
        case "Documents": return "doc"
        case "Downloads": return "arrow.down.circle"
        case "Movies": return "film"
        case "Pictures": return "photo"
        case "Music": return "music.note"
        default: break
        }
        if url.path == downloadFolder?.path { return "arrow.down.circle" }
        return url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "house" : "folder"
    }

    static func eject(_ url: URL) {
        Task.detached {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: url)
        }
    }

    /// Whether macOS lets Pluck into every folder (it can read another app's protected data).
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
        return (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
    }

    /// Full Disk Access in System Settings, for the user to turn Pluck on.
    static func askForEverything() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
