import AppKit
import SwiftUI

/// Screenshot mode, for the README pictures and for checking windows by eye: launched with
/// `-PluckScreenshot <scene>`, Pluck opens that window or sheet by itself. Never active in normal
/// use (nothing sets that argument).
///
/// Scenes: main, search:<words>, convert, subtitles, tighten, cleanup, enhance, background, blur,
/// shorts, summarize, library, player, settings, live, derush, findshots, logo. Options: `-PluckScreenshotItem <title start>`
/// picks the item, `-PluckScreenshotDownloading <n>` shows the first n paused items as
/// downloading, `-PluckScreenshotSize <w>x<h>` sizes the main window and
/// `-PluckScreenshotAppearance light|dark` picks the look.
enum ScreenshotMode {
    static var scene: String? { UserDefaults.standard.string(forKey: "PluckScreenshot") }

    #if STUDIO
    @MainActor
    static func run(manager: DownloadManager, ai: AIStudio, openWindow: OpenWindowAction, openSettings: @escaping () -> Void) {
        run(manager: manager, openWindow: openWindow, openSettings: openSettings, studio: { scene, item in
            studioScene(scene, item: item, manager: manager, ai: ai, openWindow: openWindow)
        })
    }
    #endif

    @MainActor
    static func run(manager: DownloadManager, openWindow: OpenWindowAction, openSettings: @escaping () -> Void,
                    studio: @escaping (String, DownloadItem?) -> Void = { _, _ in }) {
        guard let scene else { return }
        let defaults = UserDefaults.standard
        // The light or dark look, whatever the Mac uses.
        switch defaults.string(forKey: "PluckScreenshotAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }

        // Show Pluck's windows on whichever desktop is in front (also over a full-screen app), so
        // they're drawn and can be captured. Repeats for a while to catch windows opened later.
        var rounds = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                // A Pluck that was hidden (⌘H) when it quit comes back hidden.
                if NSApp.isHidden { NSApp.unhide(nil) }
                for window in NSApp.windows where window.styleMask.contains(.titled) || window.isSheet {
                    window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                    if window.isVisible || window.isSheet { window.orderFrontRegardless() }
                }
            }
            rounds += 1
            if rounds > 30 { timer.invalidate() }
        }

        let wanted = defaults.string(forKey: "PluckScreenshotItem")
        let finished = manager.items.filter { $0.state == .finished && $0.existingFile != nil }
        let item = finished.first { wanted == nil || $0.title.hasPrefix(wanted!) } ?? finished.first

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // In front and active, like a window someone is using.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            if let size = defaults.string(forKey: "PluckScreenshotSize")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
            }
            // Demo progress for paused items, so the main window shows downloads in action.
            let running = defaults.integer(forKey: "PluckScreenshotDownloading")
            for (index, item) in manager.items.filter({ $0.state == .paused }).prefix(running).enumerated() {
                item.state = .downloading
                item.speed = [8_400_000, 5_200_000, 11_800_000][index % 3]
                item.eta = [42, 95, 18][index % 3]
            }
            switch scene {
            case let search where search.hasPrefix("search:"):
                manager.startSearch(String(search.dropFirst("search:".count)), kind: .music)
            case "convert": if let file = item?.existingFile { manager.openConverter(for: [file]) }
            case "library": openWindow(id: "library")
            case "settings": openSettings()
            default: studio(scene, item)
            }
        }
    }

    #if STUDIO
    @MainActor
    private static func archiveSelfTest(defaults: UserDefaults) async {
        guard let folder = defaults.string(forKey: "PluckScreenshotFile"), let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        server.setEnabled(true)
        archive.add(URL(fileURLWithPath: folder, isDirectory: true))
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 900 {
            try? await Task.sleep(for: .seconds(1))
            if archive.working == nil, archive.fileCount > 0, archive.indexes.count == archive.fileCount { break }
        }
        note("indexed \(archive.indexes.count) of \(archive.fileCount) in \(Int(Date.now.timeIntervalSince(start))) s")
        server.startPairing()
        guard let code = server.pairing?.code else { return note("no pairing code") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            note("paired")
            let status = try await client.archiveStatus()
            note("status: \(status)")
            let hits = try await client.searchArchive("text", movement: nil, framing: nil)
            note("search: \(hits.count) hits")
            for hit in hits.prefix(5) { note("  \(hit.place) \(hit.start)-\(hit.end) thumb=\(hit.thumbnail?.count ?? 0)B: \(hit.description)") }
            if let first = hits.first {
                let url = try await client.fetchClip(first) { _ in }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                note("clip: \(url.lastPathComponent) \(size) bytes")
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        } catch {
            note("error: \(error.localizedDescription)")
        }
        // Back as it was: unpaired, nothing shared.
        client.forget()
        for device in server.devices { server.remove(device) }
        archive.remove(URL(fileURLWithPath: folder, isDirectory: true))
        server.setEnabled(false)
        note("done")
    }

    /// The scenes of Studio's windows and sheets.
    @MainActor
    private static func studioScene(_ scene: String, item: DownloadItem?, manager: DownloadManager, ai: AIStudio,
                                    openWindow: OpenWindowAction) {
        let defaults = UserDefaults.standard
        let batch = item.map { AIStudio.Batch([$0]) }
        switch scene {
            case "subtitles": ai.subtitleBatch = batch
            case "tighten": ai.tightenBatch = batch
            case "cleanup": ai.cleanupBatch = batch
            case "enhance": ai.enhanceItem = item
            case "background": ai.backgroundItem = item
            case "blur": ai.blurItem = item
            case "shorts": ai.shortsItem = item
            case "summarize": if let item { ai.languageAsk = AIStudio.LanguageAsk(item: item, action: .summarize) { _ in } }
            case "live":
                // -PluckScreenshotLink <stream> records it; -PluckScreenshotFile <path> analyses a file.
                openWindow(id: "liveRecorder")
                let session = LiveRecorderView.shared
                session.manager = manager
                let language = Locale(identifier: defaults.string(forKey: "PluckScreenshotLanguage") ?? "en-US")
                if let link = defaults.string(forKey: "PluckScreenshotLink") {
                    session.record(link, fromStart: false, language: language)
                }
            case "logo":
                // -PluckScreenshotFile <logo> is opened in the Logo Animator.
                let logo = defaults.string(forKey: "PluckScreenshotFile").map { URL(fileURLWithPath: $0) }
                LogoAnimatorView.openFile = logo
                openWindow(id: "logoAnimator")
                // A window left open from before has already looked for a logo: hand it over.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if LogoAnimatorView.openFile != nil, let logo {
                        NotificationCenter.default.post(name: LogoAnimatorView.openNotification, object: logo)
                    }
                }
            case "findshots":
                openWindow(id: "findShots")
            case "resolvelog":
                // Logs the open DaVinci Resolve project (with Find Shots open to show it).
                openWindow(id: "findShots")
                ResolveLogger.shared.start()
            case "office":
                openWindow(id: "officeRender")
            case "archivetest":
                // Edit Anywhere's archive, end to end in one Pluck: -PluckScreenshotFile <footage
                // folder> is indexed, a pairing over this Mac's own network, a search and a clip
                // fetched; what happens goes to -PluckScreenshotLog <file>.
                Task { @MainActor in await archiveSelfTest(defaults: defaults) }
            case "brandpack":
                // -PluckScreenshotFile <logo> is loaded.
                if let path = defaults.string(forKey: "PluckScreenshotFile") {
                    BrandPackView.openFile = URL(fileURLWithPath: path)
                }
                openWindow(id: "brandPack")
            case "delivery":
                // -PluckScreenshotFile <video> is checked.
                if let path = defaults.string(forKey: "PluckScreenshotFile") {
                    DeliveryCheckView.openFile = URL(fileURLWithPath: path)
                }
                openWindow(id: "deliveryCheck")
            case "tools":
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NotificationCenter.default.post(name: ToolsPanel.showNotification, object: nil)
                }
            case "derush":
                // -PluckScreenshotFile <file or folder> is added and analysed.
                openWindow(id: "derush")
                let derush = DerushView.shared
                derush.manager = manager
                if let path = defaults.string(forKey: "PluckScreenshotFile") {
                    derush.add([URL(fileURLWithPath: path)])
                    derush.showOverview = defaults.bool(forKey: "PluckScreenshotOverview")
                    derush.buildWhenReady = defaults.bool(forKey: "PluckScreenshotBuild")
                    derush.start(language: Locale(identifier: defaults.string(forKey: "PluckScreenshotLanguage") ?? "en-US"),
                                 lookAtPicture: true, kind: ShootPlan.Kind(rawValue: defaults.string(forKey: "derushKind") ?? "") ?? .corporate)
                }
            case "player":
                if let item, let file = item.existingFile {
                    openWindow(value: PlayerTarget(filePath: file.path, transcriptID: item.transcriptID, start: 6, tab: "transcript"))
                }
            default: break
        }
    }
    #endif
}
