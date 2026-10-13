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
    @MainActor private static var didRun = false
    @MainActor
    /// The Library: a page of Pluck Studio's window, or basic Pluck's Library window.
    private static func openLibrary(_ openWindow: OpenWindowAction) {
        #if STUDIO
        StudioNavigator.shared.show(.library)
        #else
        openWindow(id: "library")
        #endif
    }

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
        // Once per launch: Pluck Studio's Home can appear again when its page is shown.
        guard let scene, !didRun else { return }
        didRun = true
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
            case "library": openLibrary(openWindow)
            case "settings": openSettings()
            case "subscriptiontest":
                // -PluckScreenshotLink <channel or feed>, -PluckScreenshotFile <folder>, -PluckScreenshotLog <file>.
                Subscriptions.shared.manager = manager
                if let link = defaults.string(forKey: "PluckScreenshotLink"), let folder = defaults.string(forKey: "PluckScreenshotFile"),
                   let log = defaults.string(forKey: "PluckScreenshotLog") {
                    Task { await Subscriptions.shared.selfTest(link: link, folder: folder, log: URL(fileURLWithPath: log)) }
                }
            case "picker":
                // -PluckScreenshotLink <channel, playlist or feed>: the picker, nothing downloaded.
                if let link = defaults.string(forKey: "PluckScreenshotLink") { manager.add([link]) }
            case "subscriptions":
                // The Library on the first subscription of the test list (subscriptions-test.json).
                LibraryView.startCollection = Subscriptions.shared.list.first.map { .subscription($0.id, $0.title) }
                openLibrary(openWindow)
            case "remotelibrary":
                // The Library on another Mac's shared Library: -PluckScreenshotLink <its name>.
                LibraryView.startCollection = defaults.string(forKey: "PluckScreenshotLink").map { .network($0) }
                openLibrary(openWindow)
            case "editor":
                // -PluckScreenshotFile <video or song> in the Editor; -PluckScreenshotRange <in>-<out>
                // in seconds marks a range.
                if let path = defaults.string(forKey: "PluckScreenshotFile") {
                    let range = defaults.string(forKey: "PluckScreenshotRange")?.split(separator: "-").compactMap { Double($0) }
                    if let range, range.count == 2 { EditorModel.startRange = (range[0], range[1]) }
                    EditorTarget(path: path).open(openWindow)
                }
            case "clip":
                // -PluckScreenshotLink <video> in the field, with the clip row open.
                manager.pendingLink = defaults.string(forKey: "PluckScreenshotLink")
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

    /// Proxies end to end in one Pluck (a test copy, on its own port and keys): shares
    /// -PluckScreenshotFile <footage folder>, pairs over this Mac, asks for proxies in both formats
    /// and fetches them into -PluckScreenshotOutput <folder>; what happens goes to -PluckScreenshotLog.
    @MainActor private static func proxySelfTest(defaults: UserDefaults) async {
        guard let folder = defaults.string(forKey: "PluckScreenshotFile"), let output = defaults.string(forKey: "PluckScreenshotOutput"),
              let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, sync = ProxySync.shared
        let footage = URL(fileURLWithPath: folder, isDirectory: true)
        server.setEnabled(true)
        OfficeArchive.shared.add(footage)
        OfficeArchive.shared.stop()
        // -PluckScreenshotProxyFolder <folder>: proxies made there on the host (one inside the
        // footage is refused first).
        if let chosen = defaults.string(forKey: "PluckScreenshotProxyFolder") {
            do {
                try OfficeProxies.shared.choose(footage.appendingPathComponent("Day 1"))
                note("NOT refused: a proxy folder inside the footage")
            } catch {
                note("refused inside footage: \(error.localizedDescription)")
            }
            try? OfficeProxies.shared.choose(URL(fileURLWithPath: chosen, isDirectory: true))
            note("proxy folder: \(OfficeProxies.shared.chosenFolder?.path ?? "none")")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return note("no pairing code: \(server.problem ?? "")") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            note("paired")
            try await sync.loadFolders()
            note("folders: \(sync.folders.map { "\($0.name) (\($0.files))" })")
            guard let shared = sync.folders.first else { throw OfficeLink.Failure.garbled }
            for format in OfficeProxies.Format.allCases {
                let start = Date.now
                try await sync.start(shared, format: format, parent: URL(fileURLWithPath: output).appendingPathComponent(format.rawValue))
                while Date.now.timeIntervalSince(start) < 600 {
                    try? await Task.sleep(for: .seconds(2))
                    guard let job = sync.jobs.first(where: { $0.folder == shared.id && $0.format == format }),
                          let state = sync.progress[job.id] else { continue }
                    if let problem = state.problem { note("  problem: \(problem)") }
                    if state.total > 0, state.here >= state.total { break }
                }
                let state = sync.jobs.first { $0.folder == shared.id && $0.format == format }.flatMap { sync.progress[$0.id] }
                note("\(format.rawValue): \(state?.here ?? 0) of \(state?.total ?? 0) here in \(Int(Date.now.timeIntervalSince(start))) s")
            }
            // A video that isn't in the folder, and one outside it, are refused.
            for path in ["nothing.mov", "../secret.mov"] {
                do {
                    _ = try await client.ask("proxyData", ["folder": shared.id, "format": "light", "path": path, "offset": 0])
                    note("NOT refused: \(path)")
                } catch {
                    note("refused \(path): \(error.localizedDescription)")
                }
            }
            // -PluckScreenshotKeep YES: stays paired with the window open on Proxies (for a screenshot).
            if defaults.bool(forKey: "PluckScreenshotKeep") {
                note("kept")
                return
            }
            for job in sync.jobs { sync.remove(job) }
        } catch {
            note("error: \(error.localizedDescription)")
        }
        // Back as it was: unpaired, nothing shared, the host's proxies gone.
        client.forget()
        for device in server.devices { server.remove(device) }
        OfficeArchive.shared.remove(footage)
        try? OfficeProxies.shared.choose(nil)
        for format in OfficeProxies.Format.allCases {
            try? FileManager.default.removeItem(at: OfficeProxies.root.appendingPathComponent("\(OfficeProxies.id(footage))-\(format.rawValue)"))
        }
        server.setEnabled(false)
        note("done")
    }

    /// Sending files end to end in one Pluck (a test copy on its own port and keys): the inbox is
    /// -PluckScreenshotOutput <folder>; -PluckScreenshotFile <folder> is kept in step, then one
    /// file in it changes and only that one goes again; -PluckScreenshotLink <file> is sent once.
    /// Also fetches the footage's originals. What happens goes to -PluckScreenshotLog.
    @MainActor private static func sendSelfTest(defaults: UserDefaults) async {
        guard let folder = defaults.string(forKey: "PluckScreenshotFile"), let output = defaults.string(forKey: "PluckScreenshotOutput"),
              let single = defaults.string(forKey: "PluckScreenshotLink"), let logPath = defaults.string(forKey: "PluckScreenshotLog") else { return }
        var lines: [String] = []
        func note(_ text: String) {
            lines.append(text)
            try? lines.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, send = SendSync.shared
        let source = URL(fileURLWithPath: folder, isDirectory: true)
        do {
            try OfficeInbox.shared.choose(URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("inbox"))
        } catch {
            return note("inbox not set, stopped: \(error.localizedDescription)")
        }
        server.setEnabled(true)
        server.startPairing()
        guard let code = server.pairing?.code else { return note("no pairing code: \(server.problem ?? "")") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
            note("paired: \(client.office?.address ?? "-") \(client.office?.addresses ?? []) network \(client.office?.network ?? "none")")
            send.trace = { note("  " + $0) }
            send.add(folder: source)
            send.send([URL(fileURLWithPath: single)])
            var start = Date.now
            await send.pass()
            while send.sending != nil || send.files.count > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            note("first pass in \(Int(Date.now.timeIntervalSince(start))) s, problem \(send.problem ?? "none"), \(send.folders.first?.sent.count ?? 0) folder files sent")
            // One file changes: only it goes again.
            let changed = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).first { $0.pathExtension == "txt" }
            if let changed {
                try "changed at \(Date.now)".write(to: changed, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)], ofItemAtPath: changed.path)
            }
            start = .now
            var sentNames: [String] = []
            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if let name = send.sending, sentNames.last != name { sentNames.append(name) }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await send.pass()
            watcher.cancel()
            note("second pass sent \(sentNames) in \(Int(Date.now.timeIntervalSince(start))) s")
            for path in ["../escape.txt", "/etc/x", ".hidden", "a/../../b"] {
                do {
                    _ = try await client.ask("send", ["path": path, "size": 1, "modified": 0, "offset": 0, "data": Data("x".utf8).base64EncodedString()])
                    note("NOT refused: \(path)")
                } catch {
                    note("refused \(path): \(error.localizedDescription)")
                }
            }
            // The other way: the footage's originals.
            OfficeArchive.shared.add(source)
            OfficeArchive.shared.stop()
            let sync = ProxySync.shared
            try await sync.loadFolders()
            if let shared = sync.folders.first {
                start = .now
                try await sync.start(shared, format: .original, parent: URL(fileURLWithPath: output).appendingPathComponent("originals"))
                while Date.now.timeIntervalSince(start) < 300 {
                    try? await Task.sleep(for: .seconds(1))
                    if let job = sync.jobs.first, let state = sync.progress[job.id], state.total > 0, state.here >= state.total { break }
                }
                let state = sync.jobs.first.flatMap { sync.progress[$0.id] }
                note("originals: \(state?.here ?? 0) of \(state?.total ?? 0) here")
                for job in sync.jobs { sync.remove(job) }
            }
            OfficeArchive.shared.remove(source)
        } catch {
            note("error: \(error.localizedDescription)")
        }
        for folder in send.folders { send.remove(folder) }
        client.forget()
        for device in server.devices { server.remove(device) }
        try? OfficeInbox.shared.choose(nil)
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
                StudioNavigator.shared.open(windowID: "liveRecorder")
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
                StudioNavigator.shared.open(windowID: "logoAnimator")
                // A window left open from before has already looked for a logo: hand it over.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if LogoAnimatorView.openFile != nil, let logo {
                        NotificationCenter.default.post(name: LogoAnimatorView.openNotification, object: logo)
                    }
                }
            case "findshots":
                // -PluckScreenshotLink <words> is searched for.
                VisualSearchView.startQuery = defaults.string(forKey: "PluckScreenshotLink") ?? ""
                ai.searchShown = true
            case "musicfit":
                StudioNavigator.shared.open(windowID: "musicFit")
            case "resolvelog":
                // Logs the open DaVinci Resolve project (with Search open to show it).
                ai.searchShown = true
                ResolveLogger.shared.start()
            case "office":
                StudioNavigator.shared.open(windowID: "officeRender")
            case "archivetest":
                // Edit Anywhere's archive, end to end in one Pluck: -PluckScreenshotFile <footage
                // folder> is indexed, a pairing over this Mac's own network, a search and a clip
                // fetched; what happens goes to -PluckScreenshotLog <file>.
                Task { @MainActor in await archiveSelfTest(defaults: defaults) }
            case "sendtest":
                Task { @MainActor in await sendSelfTest(defaults: defaults) }
            case "proxytest":
                Task { @MainActor in
                    await proxySelfTest(defaults: defaults)
                    if defaults.bool(forKey: "PluckScreenshotKeep") {
                        UserDefaults.standard.set("home", forKey: "officeRenderSide")
                        UserDefaults.standard.set("proxies", forKey: "editAnywherePane")
                        StudioNavigator.shared.open(windowID: "officeRender")
                    }
                }
            case "brandpack":
                // -PluckScreenshotFile <logo> is loaded.
                let logo = defaults.string(forKey: "PluckScreenshotFile").map { URL(fileURLWithPath: $0) }
                BrandPackView.openFile = logo
                StudioNavigator.shared.open(windowID: "brandPack")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if BrandPackView.openFile != nil, let logo {
                        NotificationCenter.default.post(name: BrandPackView.openNotification, object: logo)
                    }
                }
            case "delivery":
                // -PluckScreenshotFile <video> is checked.
                let video = defaults.string(forKey: "PluckScreenshotFile").map { URL(fileURLWithPath: $0) }
                DeliveryCheckView.openFile = video
                StudioNavigator.shared.open(windowID: "deliveryCheck")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if DeliveryCheckView.openFile != nil, let video {
                        NotificationCenter.default.post(name: DeliveryCheckView.openNotification, object: video)
                    }
                }
            case "tools":
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NotificationCenter.default.post(name: ToolsPanel.showNotification, object: nil)
                }
            case "derush":
                // -PluckScreenshotFile <file or folder> is added and analysed.
                StudioNavigator.shared.open(windowID: "derush")
                let derush = DerushView.shared
                derush.manager = manager
                if let path = defaults.string(forKey: "PluckScreenshotFile") {
                    derush.add([URL(fileURLWithPath: path)])
                    derush.showOverview = defaults.bool(forKey: "PluckScreenshotOverview")
                    derush.buildWhenReady = defaults.bool(forKey: "PluckScreenshotBuild")
                    derush.start(language: Locale(identifier: defaults.string(forKey: "PluckScreenshotLanguage") ?? "en-US"),
                                 lookAtPicture: true, kind: ShootPlan.Kind(rawValue: defaults.string(forKey: "derushKind") ?? "") ?? .corporate)
                }
            case "photo":
                // -PluckScreenshotPhotos <folder>: an album of its photos on the Photo page.
                if let folder = defaults.string(forKey: "PluckScreenshotPhotos") {
                    let catalog = PhotoCatalog.shared
                    if catalog.albums.isEmpty {
                        catalog.newAlbum(named: URL(fileURLWithPath: folder).lastPathComponent,
                                         with: PhotoCatalog.photos(in: [URL(fileURLWithPath: folder)]))
                    }
                }
                StudioNavigator.shared.show(.photo)
            case "project":
                // -PluckScreenshotFiles <a|b|c>: a project with these files.
                // -PluckScreenshotStabilize <file>: steadies it.
                if let file = defaults.string(forKey: "PluckScreenshotStabilize") { Stabilizer.shared.start(file) }
                // -PluckScreenshotProject <file.json>: this project, opened.
                if let file = defaults.string(forKey: "PluckScreenshotProject"), let data = try? Data(contentsOf: URL(fileURLWithPath: file)) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let project = try? decoder.decode(Project.self, from: data) {
                        ProjectStore.save(project)
                        StudioNavigator.shared.open(project)
                    }
                }
                if let list = defaults.string(forKey: "PluckScreenshotFiles") {
                    StudioNavigator.shared.newProject(with: list.split(separator: "|").map { URL(fileURLWithPath: String($0)) },
                                                      named: defaults.string(forKey: "PluckScreenshotName"))
                }
            case "player":
                if let item, let file = item.existingFile {
                    PlayerTarget(filePath: file.path, transcriptID: item.transcriptID, start: 6, tab: "transcript").open(openWindow)
                }
            default: break
        }
    }
    #endif
}
