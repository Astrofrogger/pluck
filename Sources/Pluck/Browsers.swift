import AppKit

/// Browsers yt-dlp can read cookies from on macOS.
enum CookieBrowser: String, CaseIterable, Identifiable {
    case safari, chrome, chromeBeta, firefox, firefoxNightly, zen, brave, edge, vivaldi, opera, chromium

    var id: String { rawValue }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Google Chrome"
        case .chromeBeta: "Google Chrome Beta"
        case .firefox: "Firefox"
        case .firefoxNightly: "Firefox Nightly"
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
        case .chromeBeta: "com.google.Chrome.beta"
        case .firefox: "org.mozilla.firefox"
        case .firefoxNightly: "org.mozilla.nightly"
        case .zen: "app.zen-browser.zen"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        case .vivaldi: "com.vivaldi.Vivaldi"
        case .opera: "com.operasoftware.Opera"
        case .chromium: "org.chromium.Chromium"
        }
    }

    /// Variants that share the same cookie storage: Firefox Developer Edition and Beta keep their
    /// profiles in Firefox's folder. (Chrome Canary and Edge Beta/Dev don't: they have folders of
    /// their own, which yt-dlp's "chrome" and "edge" don't read.)
    private var bundleIDs: [String] {
        switch self {
        case .firefox: [bundleID, "org.mozilla.firefoxdeveloperedition", "org.mozilla.firefoxbeta"]
        default: [bundleID]
        }
    }

    var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }
    var isInstalled: Bool { appURL != nil }

    /// The value for yt-dlp's --cookies-from-browser. Zen and Firefox Nightly are passed as
    /// Firefox pointed at their profile folder, Chrome Beta as Chrome pointed at its own folder.
    var argument: String? {
        switch self {
        case .zen: Self.zenProfile().map { "firefox:\($0.path)" }
        case .firefoxNightly: Self.nightlyProfile().map { "firefox:\($0.path)" }
        case .chromeBeta: "chrome:\(Self.support.appendingPathComponent("Google/Chrome Beta").path)"
        default: rawValue
        }
    }

    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Picks a browser the first time Pluck runs, so sites that need a login (and YouTube's bot
    /// check) work without a trip to Settings: the default browser if Pluck can read its cookies,
    /// otherwise the first installed one it can. A choice made in Settings is never overwritten.
    static func chooseOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier,
              defaults.persistentDomain(forName: domain)?[Prefs.cookiesBrowser] == nil else { return }
        // Firefox-based browsers first: they never ask for the keychain.
        let fallback: [CookieBrowser] = [.firefox, .zen, .firefoxNightly, .chrome, .chromeBeta, .brave, .edge, .vivaldi, .opera, .chromium, .safari]
        let pick = ([defaultBrowser].compactMap { $0 } + fallback).first { $0.isInstalled && $0.hasReadableCookies }
        defaults.set(pick?.rawValue ?? "none", forKey: Prefs.cookiesBrowser)
    }

    /// Once per browser: when the chosen browser's cookies have become unreadable because of
    /// macOS 27's protection, say so (downloads go on without them; see `accessProblem`).
    @MainActor static func warnIfBlocked() {
        let defaults = UserDefaults.standard
        guard let browser = CookieBrowser(rawValue: defaults.string(forKey: Prefs.cookiesBrowser) ?? ""),
              browser.isInstalled, browser.access == .blockedByMacOS else { return }
        let key = "cookiesBlockedWarned-\(browser.rawValue)"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = String(localized: "Pluck can no longer use \(browser.name)’s cookies")
        alert.informativeText = browser.accessProblem ?? ""
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// The browser that opens web links, if it's one yt-dlp can read cookies from.
    static var defaultBrowser: CookieBrowser? {
        guard let web = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: web),
              let id = Bundle(url: app)?.bundleIdentifier else { return nil }
        return allCases.first { $0.bundleIDs.contains(id) }
    }

    /// Whether Pluck can read this browser's cookies.
    enum Access: Equatable {
        case readable
        /// Never used on this Mac (no profile with cookies).
        case notUsed
        /// macOS 27 locks the data of Chrome, Brave, Edge and Firefox to the browser itself: the
        /// folder is there, but no other app may read it, not even with Full Disk Access.
        case blockedByMacOS
        /// Safari's cookies are behind Full Disk Access.
        case needsFullDiskAccess
    }

    /// Whether this browser has been used on this Mac and Pluck may read its cookies.
    var hasReadableCookies: Bool { access == .readable }

    /// Tries to read the cookies, the way yt-dlp will: a folder that merely exists isn't enough
    /// (macOS 27's protection lets apps see a protected folder but not open anything in it).
    var access: Access {
        switch self {
        case .safari:
            let file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            guard FileManager.default.fileExists(atPath: file.path) else { return .notUsed }
            return Self.canOpen(file) ? .readable : .needsFullDiskAccess
        case .zen:
            return Self.profileAccess(in: "zen/Profiles")
        case .firefoxNightly:
            return Self.profileAccess(in: "Firefox/Profiles") { $0.lastPathComponent.localizedCaseInsensitiveContains("nightly") }
        case .firefox:
            return Self.profileAccess(in: "Firefox/Profiles")
        case .chrome, .chromeBeta, .brave, .edge, .vivaldi, .opera, .chromium:
            let folder = Self.support.appendingPathComponent(chromiumFolder)
            guard FileManager.default.fileExists(atPath: folder.path) else { return .notUsed }
            guard let profiles = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
                return Self.isBlocked(folder) ? .blockedByMacOS : .notUsed
            }
            // Opera keeps its cookies in the folder itself; the others in a profile folder.
            let candidates = [folder.appendingPathComponent("Cookies")]
                + profiles.flatMap { [$0.appendingPathComponent("Cookies"), $0.appendingPathComponent("Network/Cookies")] }
            guard let cookies = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return .notUsed }
            return Self.canOpen(cookies) ? .readable : .blockedByMacOS
        }
    }

    /// Where a Chromium-based browser keeps its profiles (as yt-dlp looks for them).
    private var chromiumFolder: String {
        switch self {
        case .chrome: "Google/Chrome"
        case .chromeBeta: "Google/Chrome Beta"
        case .brave: "BraveSoftware/Brave-Browser"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "com.operasoftware.Opera"
        default: "Chromium"
        }
    }

    private static func canOpen(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        try? handle.close()
        return true
    }

    /// Whether listing the folder is refused by the system (EPERM), rather than failing otherwise.
    private static func isBlocked(_ folder: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            return false
        } catch let error as NSError {
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            return error.code == NSFileReadNoPermissionError || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES)
        }
    }

    /// Firefox-style profiles: readable if a profile with cookies opens.
    private static func profileAccess(in folder: String, where matches: (URL) -> Bool = { _ in true }) -> Access {
        let profiles = support.appendingPathComponent(folder, isDirectory: true)
        // Firefox's whole folder is protected on macOS 27, so the Profiles folder inside it is too.
        let root = profiles.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.path) else { return .notUsed }
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil) else {
            return isBlocked(profiles) || isBlocked(root) ? .blockedByMacOS : .notUsed
        }
        let files = dirs.filter(matches).map { $0.appendingPathComponent("cookies.sqlite") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let file = files.first else { return .notUsed }
        return canOpen(file) ? .readable : .blockedByMacOS
    }

    /// What's wrong, for Settings (nil when the cookies can be read).
    var accessProblem: String? {
        switch access {
        case .readable: nil
        case .notUsed: String(localized: "Pluck can’t find any cookies from \(name) on this Mac. Sign in to the site in \(name) first.")
        case .blockedByMacOS: String(localized: "macOS 27 no longer lets other apps read \(name)’s cookies, not even with Full Disk Access. Downloads still work, just without your logins. For members-only or age-restricted videos, pick Safari, Zen, Vivaldi, Opera or Chrome Beta.")
        case .needsFullDiskAccess: String(localized: "Safari’s cookies need Full Disk Access: turn on Pluck in System Settings → Privacy & Security → Full Disk Access.")
        }
    }

    /// The Zen profile whose cookies were used most recently.
    static func zenProfile() -> URL? {
        newestProfile(in: "zen/Profiles")
    }

    /// Firefox Nightly's profile ("….default-nightly"), next to Firefox's own in the same folder.
    static func nightlyProfile() -> URL? {
        newestProfile(in: "Firefox/Profiles") { $0.lastPathComponent.localizedCaseInsensitiveContains("nightly") }
    }

    private static func newestProfile(in folder: String, where matches: (URL) -> Bool = { _ in true }) -> URL? {
        let profiles = support.appendingPathComponent(folder, isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: profiles, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .filter(matches)
            .compactMap { dir -> (URL, Date)? in
                let cookies = dir.appendingPathComponent("cookies.sqlite")
                guard let date = try? cookies.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (dir, date)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
