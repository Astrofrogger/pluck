import AppKit
import SwiftUI

/// The "What's New" sheet shown on the first launch after an update: the big features of the newest
/// release, older releases since the version that last ran folded away, and a link to the full
/// list of fixes on GitHub.
enum WhatsNew {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        /// A picture for the card (Pluck Studio): a JPEG in Resources/WhatsNew, by name.
        var image: String? = nil
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
        let previous = defaults.string(forKey: lastVersionKey) ?? (isFreshInstall ? nil : oldestNotes)
        EditionChoice.prepare(isUpdate: previous != nil)
        guard let previous else {
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
        #if STUDIO
        let hosting = NSHostingController(rootView: StudioWhatsNewView(releases: pending) { window?.close() })
        #else
        let hosting = NSHostingController(rootView: WhatsNewView(releases: pending) { window?.close() })
        #endif
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = String(localized: "What’s New in Pluck")
        newWindow.identifier = NSUserInterfaceItemIdentifier("whatsnew")
        #if STUDIO
        newWindow.appearance = NSAppearance(named: .darkAqua)  // Studio is dark, whatever the Mac uses
        #endif
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

    /// The big features of each release, written for people rather than developers, with Pluck
    /// Studio's own (in Studio/WhatsNewStudio.swift, so basic Pluck isn't built with them) added in.
    /// Fixes and small changes aren't listed: the sheet links to the release on GitHub for those.
    /// Add the new version's entry before releasing it (an entry with no items still shows that link).
    static var releases: [Release] {
        var all = shared
        #if STUDIO
        for extra in studioReleases {
            if let n = all.firstIndex(where: { $0.version == extra.version }) {
                all[n] = Release(version: extra.version, items: all[n].items + extra.items)
            } else {
                all.append(extra)
            }
        }
        #endif
        return all.sorted { isNewer($0.version, than: $1.version) }
    }

    /// Notes for everyone (both editions).
    private static var shared: [Release] {
        [
            Release(version: "4.0.0", items: []),
        ]
    }

    /// Everything else in that release, on GitHub.
    static func releasePage(_ version: String) -> URL {
        SupportLinks.gitHub.appending(path: "releases/tag/v\(version)")
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
                VStack(alignment: .leading, spacing: Design.Spacing.section) {
                    if let newest = releases.first {
                        ForEach(newest.items, content: itemRow)
                    }
                    // Older versions stay out of the way: the newest one's big features come first.
                    if releases.count > 1 {
                        DisclosureGroup("Earlier versions") {
                            VStack(alignment: .leading, spacing: Design.Spacing.section) {
                                ForEach(releases.dropFirst()) { release in
                                    Text("Version \(release.version)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(release.items, content: itemRow)
                                }
                            }
                            .padding(.top, Design.Spacing.controls)
                        }
                    }
                    if let newest = releases.first {
                        row("wrench.and.screwdriver", String(localized: "Bug fixes and improvements"),
                            Link("All changes on GitHub", destination: WhatsNew.releasePage(newest.version)))
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
            .padding(Design.Spacing.sheet)
        }
        .frame(width: 480)
    }

    private func itemRow(_ item: WhatsNew.Item) -> some View {
        row(item.symbol, item.title, Text(item.detail).foregroundStyle(.secondary))
            .accessibilityElement(children: .combine)
    }

    private func row(_ symbol: String, _ title: String, _ detail: some View) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Design.Brand.chosen)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                detail.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
