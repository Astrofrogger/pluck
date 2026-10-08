import AppKit

/// Browsers yt-dlp can read cookies from on macOS.
enum CookieBrowser: String, CaseIterable, Identifiable {
    case safari, chrome, firefox, zen, brave, edge, vivaldi, opera, chromium

    var id: String { rawValue }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .firefox: "Firefox"
        case .zen: "Zen"
        case .brave: "Brave"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .chromium: "Chromium"
        }
    }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .firefox: "org.mozilla.firefox"
        case .zen: "app.zen-browser.zen"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .chromium: "org.chromium.Chromium"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    var isInstalled: Bool { appURL != nil }

    /// The value for yt-dlp's --cookies-from-browser. Zen is Firefox-based, so it's passed as
    /// Firefox pointed at Zen's profile folder.
    var argument: String? {
        guard self == .zen else { return rawValue }
        return Self.zenProfile().map { "firefox:\($0.path)" }
    }

    /// The Zen profile whose cookies were used most recently.
    static func zenProfile() -> URL? {
        let profiles = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("zen/Profiles", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { dir -> (URL, Date)? in
                let cookies = dir.appendingPathComponent("cookies.sqlite")
                guard let date = try? cookies.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (dir, date)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
