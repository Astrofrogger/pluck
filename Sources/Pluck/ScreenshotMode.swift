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

    @MainActor
    static func run(manager: DownloadManager, ai: AIStudio, openWindow: OpenWindowAction, openSettings: @escaping () -> Void) {
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
        let batch = item.map { AIStudio.Batch([$0]) }

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
            case "subtitles": ai.subtitleBatch = batch
            case "tighten": ai.tightenBatch = batch
            case "cleanup": ai.cleanupBatch = batch
            case "enhance": ai.enhanceItem = item
            case "background": ai.backgroundItem = item
            case "blur": ai.blurItem = item
            case "shorts": ai.shortsItem = item
            case "summarize": if let item { ai.languageAsk = AIStudio.LanguageAsk(item: item, action: .summarize) { _ in } }
            case "library": openWindow(id: "library")
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
            case "settings": openSettings()
            default: break
            }
        }
    }
}
