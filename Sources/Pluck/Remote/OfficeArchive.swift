import Foundation

/// The folders this Mac shares with paired Macs in Edit Anywhere (Share this Mac → Folders).
/// Paths never leave this Mac; RemoteShares keeps a bookmark, an id and the watches of each.
/// (Named after the archive search it once had: the stored key stays, so shares are kept.)
@MainActor
@Observable
final class OfficeArchive {
    static let shared = OfficeArchive()
    static let foldersKey = "officeArchiveFolders"

    private(set) var folders: [URL] = []

    private init() {
        folders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Shot clips the old archive search made for paired Macs: no longer made, so they go.
    static func removeOldClips() {
        let clips = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Office Render/Clips", isDirectory: true)
        try? FileManager.default.removeItem(at: clips)
    }

    /// False when the folder holds the inbox or is inside it: what paired Macs send never becomes shared content.
    @discardableResult
    func add(_ folder: URL) -> Bool {
        guard !OfficeInbox.overlaps(folder, OfficeInbox.shared.folder) else { return false }
        guard !folders.contains(folder) else { return true }
        folders.append(folder)
        save()
        return true
    }

    func remove(_ folder: URL) {
        // Its proxies stay (until deleted under Proxies), so they're remembered by name.
        OfficeProxies.shared.remember(folder)
        folders.removeAll { $0 == folder }
        save()
    }

    /// Snapshot scenes only: these folders shown, nothing stored.
    func showSample(_ sample: [URL]) {
        guard ScreenshotMode.scene != nil else { return }
        folders = sample
    }

    private func save() {
        UserDefaults.standard.set(folders.map(\.path), forKey: Self.foldersKey)
    }

    /// The videos in the folders, leaving out the inbox: what paired Macs send never becomes footage.
    nonisolated static func videoFiles(in folders: [URL], skipping inbox: URL) -> [URL] {
        // (realpath, not resolvingSymlinksInPath: that drops /private, the enumerator keeps it.)
        func real(_ url: URL) -> String {
            guard let path = realpath(url.path, nil) else { return url.standardizedFileURL.path }
            defer { free(path) }
            return String(cString: path)
        }
        let inboxPath = real(inbox)
        var found: [URL] = []
        for folder in folders where !(real(folder) + "/").hasPrefix(inboxPath + "/") {
            let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = items?.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, real(url) == inboxPath {
                    items?.skipDescendants()
                    continue
                }
                if Converting.isVideo(url) { found.append(url) }
            }
        }
        return found
    }
}
