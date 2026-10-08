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

    /// Variants that share the same cookie storage, e.g. Firefox Developer Edition and Nightly.
    private var bundleIDs: [String] {
        switch self {
        case .firefox: [bundleID, "org.mozilla.firefoxdeveloperedition", "org.mozilla.firefoxbeta", "org.mozilla.nightly"]
        case .chrome: [bundleID, "com.google.Chrome.beta", "com.google.Chrome.canary"]
        case .edge: [bundleID, "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev"]
        default: [bundleID]
        }
    }

    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
    var isInstalled: Bool { appURL != nil }

    /// The value for yt-dlp's --cookies-from-browser. Zen is Firefox-based, so it's passed as
    /// Firefox pointed at Zen's profile folder.
    var argument: String? {
        guard self == .zen else { return rawValue }
        return Self.zenProfile().map { "firefox:\($0.path)" }
    }

    /// Picks a browser the first time Pluck runs, so sites that need a login (and YouTube's bot
    /// check) work without a trip to Settings: the default browser if Pluck can read its cookies,
    /// otherwise the first installed one it can. A choice made in Settings is never overwritten.
    static func chooseOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier,
              defaults.persistentDomain(forName: domain)?[Prefs.cookiesBrowser] == nil else { return }
        // Firefox-based browsers first: they never ask for the keychain.
        let fallback: [CookieBrowser] = [.firefox, .zen, .chrome, .brave, .edge, .vivaldi, .opera, .chromium, .safari]
        let pick = ([defaultBrowser].compactMap { $0 } + fallback).first { $0.isInstalled && $0.hasReadableCookies }
        defaults.set(pick?.rawValue ?? "none", forKey: Prefs.cookiesBrowser)
    }

    /// The browser that opens web links, if it's one yt-dlp can read cookies from.
    static var defaultBrowser: CookieBrowser? {
        guard let web = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: web),
              let id = Bundle(url: app)?.bundleIdentifier else { return nil }
        return allCases.first { $0.bundleIDs.contains(id) }
    }

    /// Whether this browser has been used on this Mac and Pluck may read its cookies. Safari's are
    /// behind Full Disk Access, so they're only usable when the file actually opens.
    var hasReadableCookies: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        switch self {
        case .safari:
            let file = home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            try? handle.close()
            return true
        case .zen:
            return Self.zenProfile() != nil
        case .firefox:
            let profiles = support.appendingPathComponent("Firefox/Profiles")
            let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
            return dirs.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cookies.sqlite").path) }
        case .chrome, .brave, .edge, .vivaldi, .opera, .chromium:
            let folder = switch self {
            case .chrome: "Google/Chrome"
            case .brave: "BraveSoftware/Brave-Browser"
            case .edge: "Microsoft Edge"
            case .vivaldi: "Vivaldi"
            case .opera: "com.operasoftware.Opera"
            default: "Chromium"
            }
            return FileManager.default.fileExists(atPath: support.appendingPathComponent(folder).path)
        }
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
