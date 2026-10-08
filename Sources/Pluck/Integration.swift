import AppKit

/// "Download with Pluck" in the Services menu (right-click a link or selected text in any app).
/// Choosing a service is the user's own action, so its links start downloading straight away.
@MainActor
final class ServiceProvider: NSObject {
    let manager: DownloadManager

    init(manager: DownloadManager) {
        self.manager = manager
    }

    @objc func downloadWithPluck(_ pasteboard: NSPasteboard, userData: String?,
                                 error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let links = Links.extract(from: pasteboard)
        guard !links.isEmpty else {
            error.pointee = "No link to download was selected." as NSString
            return
        }
        manager.add(links)
    }
}

/// Handles pluck://download?url=… (for example from a browser bookmarklet). Any website can open
/// such a link, so it never starts a download by itself: it fills in Pluck's link field and
/// brings the window forward, and the user presses Return to start.
enum URLScheme {
    @MainActor static func handle(_ url: URL, manager: DownloadManager) {
        guard url.scheme?.lowercased() == "pluck",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let link = Links.validated(value)
        else { return }
        manager.pendingLink = link
        AppDelegate.openMainWindow?()
    }
}

enum Links {
    /// Accepts web links and Spotify links only.
    static func validated(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Spotify.parse(trimmed) != nil { return trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return trimmed
    }

    /// Every distinct link on a pasteboard: copied URLs first, then any found in selected text.
    static func extract(from pasteboard: NSPasteboard) -> [String] {
        var found: [String] = []
        func add(_ candidate: String) {
            if let link = validated(candidate), !found.contains(link) { found.append(link) }
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        urls.forEach { add($0.absoluteString) }
        if let text = pasteboard.string(forType: .string),
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url { add(url.absoluteString) }
            }
            if found.isEmpty { add(text) }
        }
        return found
    }
}
