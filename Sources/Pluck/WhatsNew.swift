import AppKit
import SwiftUI

/// The "What's New" sheet shown on the first launch after an update. It lists every release newer
/// than the version that last ran, so someone coming from 1.1.0 sees everything since then and
/// someone coming from the previous version sees just the latest notes.
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    struct Release: Identifiable {
        let version: String
        let items: [Item]
        var id: String { version }
    }

    /// The version that last ran; Pluck 1.6.1 and earlier didn't record it.
    private static let lastVersionKey = "lastVersion"
    /// Assumed for people updating from a version that didn't record itself, so they see it all.
    private static let oldestNotes = "1.1.0"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Releases to show at launch, newest first. Must run before anything else writes preferences,
    /// because a fresh install (no preferences yet) isn't an update and shows nothing.
    @MainActor static var pending: [Release] = []

    @MainActor static func prepare() {
        let defaults = UserDefaults.standard
        let current = currentVersion
        let isFreshInstall = Bundle.main.bundleIdentifier
            .flatMap { defaults.persistentDomain(forName: $0) }?.isEmpty ?? true
        guard let previous = defaults.string(forKey: lastVersionKey) ?? (isFreshInstall ? nil : oldestNotes) else {
            markSeen()
            return
        }
        pending = releases
            .filter { isNewer($0.version, than: previous) && !isNewer($0.version, than: current) }
            .sorted { isNewer($0.version, than: $1.version) }
        if pending.isEmpty { markSeen() }
    }

    @MainActor private static var window: NSWindow?

    /// Opens the notes in their own window, so they also appear for people who start Pluck in the
    /// menu bar only. Closing the window (or Continue) marks them as read.
    @MainActor static func showIfNeeded() {
        guard !pending.isEmpty, window == nil else { return }
        let hosting = NSHostingController(rootView: WhatsNewView(releases: pending) { window?.close() })
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = String(localized: "What’s New in Pluck")
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { _ in
            MainActor.assumeIsolated {
                markSeen()
                window = nil
            }
        }
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @MainActor static func markSeen() {
        pending = []
        UserDefaults.standard.set(currentVersion, forKey: lastVersionKey)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) where (i < x.count ? x[i] : 0) != (i < y.count ? y[i] : 0) {
            return (i < x.count ? x[i] : 0) > (i < y.count ? y[i] : 0)
        }
        return false
    }

    /// Every release since 1.1.0, written for people rather than developers. Add the new version's
    /// notes here before releasing it.
    static var releases: [Release] {
        [
            Release(version: "1.7.1", items: [
                Item(symbol: "scissors", title: String(localized: "Trim your own videos and songs"),
                     detail: String(localized: "When converting a file, choose Only part of the file to keep just a section, or use it with any other option.")),
                Item(symbol: "photo.on.rectangle.angled", title: String(localized: "Make GIFs"),
                     detail: String(localized: "Turn a video, or part of it, into an animated GIF in three sizes.")),
            ]),
            Release(version: "1.7.0", items: [
                Item(symbol: "doc.on.clipboard", title: String(localized: "Many links at once"),
                     detail: String(localized: "Paste or drop a list of links, or a text file full of them, and Pluck downloads them all.")),
                Item(symbol: "list.number", title: String(localized: "Split into chapters"),
                     detail: String(localized: "Turn on Split into Chapters in the format menu to save DJ mixes and full albums as separate, tagged tracks.")),
                Item(symbol: "arrow.triangle.2.circlepath", title: String(localized: "Convert files on your Mac"),
                     detail: String(localized: "Drop a video or song on Pluck to extract the audio, convert it to MP4, or compress it to the size and resolution you choose.")),
                Item(symbol: "checkmark.seal", title: String(localized: "Lossless badge"),
                     detail: String(localized: "Downloads that stay lossless from the source to your file are marked Lossless.")),
                Item(symbol: "bell.badge", title: String(localized: "Buttons in notifications"),
                     detail: String(localized: "Play a finished download or show it in Finder straight from the notification.")),
                Item(symbol: "sparkles", title: String(localized: "What’s New after updates"),
                     detail: String(localized: "After every update Pluck shows what changed, just like this.")),
                Item(symbol: "globe", title: String(localized: "Speaks your language"),
                     detail: String(localized: "Pluck is now also in German, French, Spanish, Italian, Portuguese, Japanese, Korean and Chinese, and follows your Mac’s language.")),
            ]),
            Release(version: "1.6.1", items: [
                Item(symbol: "person.badge.key", title: String(localized: "Cookies work out of the box"),
                     detail: String(localized: "Pluck picks the browser to use cookies from by itself, so sites that need a login just work. You can change it in Settings → Advanced.")),
            ]),
            Release(version: "1.6.0", items: [
                Item(symbol: "magnifyingglass", title: String(localized: "Search inside Pluck"),
                     detail: String(localized: "Type a song or video name instead of a link, then download it from YouTube Music or YouTube with one click.")),
                Item(symbol: "quote.bubble", title: String(localized: "Lyrics"),
                     detail: String(localized: "Songs get their lyrics, so they show up in Apple Music and on iPhone.")),
                Item(symbol: "pause.circle", title: String(localized: "Pause and resume"),
                     detail: String(localized: "Pause big downloads and continue later, even after quitting Pluck.")),
                Item(symbol: "arrow.clockwise", title: String(localized: "Automatic retry"),
                     detail: String(localized: "If the connection drops, Pluck waits for the internet to come back and carries on.")),
                Item(symbol: "folder", title: String(localized: "Tidy files"),
                     detail: String(localized: "Choose how files are named. Albums and playlists get their own folder, and Pluck notices songs you already have.")),
            ]),
            Release(version: "1.5.0", items: [
                Item(symbol: "keyboard", title: String(localized: "Your own shortcut"),
                     detail: String(localized: "Download the link you copied from any app with ⌃⌥⌘D, or set your own shortcut in Settings → General.")),
                Item(symbol: "waveform", title: String(localized: "Better audio"),
                     detail: String(localized: "Pluck takes the best audio on offer and shows the quality you got. With YouTube Premium that’s about 256 kbps.")),
                Item(symbol: "character.bubble", title: String(localized: "Nederlands"),
                     detail: String(localized: "Pluck is translated into Dutch and follows your Mac’s language.")),
            ]),
            Release(version: "1.4.0", items: [
                Item(symbol: "checklist", title: String(localized: "Pick from playlists"),
                     detail: String(localized: "Paste a YouTube playlist or a Spotify album or playlist and choose one video, a few, or all of them.")),
            ]),
            Release(version: "1.3.0", items: [
                Item(symbol: "scissors", title: String(localized: "Download a clip"),
                     detail: String(localized: "Click the scissors to download just part of a video, like 1:30 to 2:45.")),
                Item(symbol: "list.bullet.rectangle", title: String(localized: "Your downloads stay listed"),
                     detail: String(localized: "The list survives quitting. Press Space for Quick Look, or drag a download into Finder or Mail.")),
                Item(symbol: "contextualmenu.and.cursorarrow", title: String(localized: "Download from any app"),
                     detail: String(localized: "Right-click a link and choose Services → Download with Pluck.")),
            ]),
            Release(version: "1.2.3", items: [
                Item(symbol: "lock.shield", title: String(localized: "Safer downloads"),
                     detail: String(localized: "Browser cookies are never sent to videos found on web pages, and the tools Pluck downloads are checked for their developers’ signatures.")),
            ]),
            Release(version: "1.2.2", items: [
                Item(symbol: "cup.and.saucer", title: String(localized: "Support Pluck"),
                     detail: String(localized: "A new Support tab in Settings to buy me a coffee or star Pluck on GitHub.")),
            ]),
            Release(version: "1.2.1", items: [
                Item(symbol: "gauge.with.dots.needle.67percent", title: String(localized: "Live progress"),
                     detail: String(localized: "Progress, speed and status now update smoothly instead of in jumps.")),
            ]),
            Release(version: "1.2.0", items: [
                Item(symbol: "globe", title: String(localized: "Almost any website"),
                     detail: String(localized: "When yt-dlp doesn’t know a page, Pluck finds the video on it, including embedded Vimeo, YouTube and SoundCloud players.")),
                Item(symbol: "menubar.rectangle", title: String(localized: "Lives in your menu bar"),
                     detail: String(localized: "Paste links and follow progress from the menu bar. Pluck keeps running there when you close the window, and can open at login.")),
                Item(symbol: "macwindow", title: String(localized: "A fresh look"),
                     detail: String(localized: "Liquid Glass on macOS 26 and a redesigned Settings window.")),
                Item(symbol: "accessibility", title: String(localized: "Works with VoiceOver"),
                     detail: String(localized: "Every button has a proper label.")),
            ]),
        ]
    }
}

struct WhatsNewView: View {
    let releases: [WhatsNew.Release]
    let onClose: () -> Void

    private var subtitle: String {
        guard let newest = releases.first else { return "" }
        if releases.count == 1 { return String(localized: "Version \(newest.version)") }
        return String(localized: "Everything new up to version \(newest.version)")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("What’s New in Pluck")
                    .font(.title2.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 14) {
                            if releases.count > 1 {
                                Text("Version \(release.version)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(release.items) { item in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: item.symbol)
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                        .frame(width: 32)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.headline)
                                        Text(item.detail)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: releases.count > 1 ? 400 : nil)
            .fixedSize(horizontal: false, vertical: releases.count == 1)

            Button {
                onClose()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(24)
        }
        .frame(width: 480)
    }
}
