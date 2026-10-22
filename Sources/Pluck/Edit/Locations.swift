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

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let own = ["Desktop", "Documents", "Downloads", "Movies", "Pictures"].map { home.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let drives = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path != "/" && (try? $0.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) != false }
        places = [home] + own + drives
        favorites = [home] + own
        self.drives = drives
        seesEverything = Self.hasFullDiskAccess()
    }

    static func isDrive(_ url: URL) -> Bool { url.path.hasPrefix("/Volumes/") }

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
        default: return "house"
        }
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
