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

        // -PluckScreenshotSeed <folder>: its videos, songs and photos added as finished items (once),
        // so the list, Home and the Library have something to show.
        // -PluckScreenshotUpdatePrompt YES: a new version offered in its window.
        if defaults.bool(forKey: "PluckScreenshotUpdatePrompt") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                AppDelegate.shared?.appUpdater.pretendAvailable("3.2.0", notes: """
                    ## Pluck Studio 3.2

                    - **Whole RED takes in Quick Look:** a take the camera split into several files plays from start to end.
                    - **Updates you won't miss:** a new version is offered in a window of its own.

                    ### Download
                    Pick one of the two files below.
                    """)
            }
        }
        // -PluckScreenshotSendClips <file>, -PluckScreenshotLog <file>: the clip sent to Resolve as the
        // app sends it (into "Pluck Test"), and what came of it.
        if let file = defaults.string(forKey: "PluckScreenshotSendClips"), let log = defaults.string(forKey: "PluckScreenshotLog") {
            Task {
                let line: String
                do {
                    let sent = try await Resolve.sendClips([URL(fileURLWithPath: file)], bin: ["Pluck Test", "Sub"])
                    line = "ok \(sent.imported) \(sent.skipped) \(sent.linked) \(sent.project)"
                } catch {
                    line = "failed \(error.localizedDescription)"
                }
                try? line.write(toFile: log, atomically: true, encoding: .utf8)
            }
        }
        // -PluckScreenshotBinChooser <file>: the dialog asking which bin of Resolve it goes in.
        if let file = defaults.string(forKey: "PluckScreenshotBinChooser") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Resolve.sendClipsAndShow([URL(fileURLWithPath: file)]) }
        }
        // -PluckScreenshotUpdateReady YES: an update ready to go in when Pluck quits.
        if defaults.bool(forKey: "PluckScreenshotUpdateReady") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppDelegate.shared?.appUpdater.pretendReady("3.2.0") }
        }
        // -PluckScreenshotUpdateBar <0…1>: an update shown as installing, that far downloaded.
        if let fraction = Double(defaults.string(forKey: "PluckScreenshotUpdateBar") ?? "") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                AppDelegate.shared?.appUpdater.pretendInstalling("\(Edition.name) 3.2.0", received: Int64(fraction * 114_000_000), of: 114_000_000)
            }
        }
        if let seed = defaults.string(forKey: "PluckScreenshotSeed") {
            let files = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: seed), includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.hasDirectoryPath }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            let known = Set(manager.items.compactMap { $0.fileURL?.path })
            _ = manager.addLocalFiles(files.filter { !known.contains($0.path) })
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
            case "downloadtest":
                // -PluckScreenshotLink <link> downloaded into each of -PluckScreenshotFile <a|b|…>; to -PluckScreenshotLog.
                Task { await DownloadSelfTest.run(defaults: defaults, manager: manager) }
            case "converttest":
                // Every file in -PluckScreenshotFile <folder> through each conversion, into -PluckScreenshotOutput; to -PluckScreenshotLog.
                Task { await ConvertSelfTest.run(defaults: defaults, manager: manager) }
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
                    #if STUDIO
                    StudioNavigator.shared.open(EditorTarget(path: path), range: range.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil })
                    #else
                    if let range, range.count == 2 { EditorModel.startRange = (range[0], range[1]) }
                    EditorTarget(path: path).open(openWindow)
                    #endif
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
            case "logogolden":
                // Golden frames for the Logo Animator: every logo in -PluckScreenshotFile <folder>,
                // every style and outro at eight moments, to -PluckScreenshotOutput <folder>
                // (PNGs and manifest.txt of pixel hashes); -PluckScreenshotBaseline <folder> compares
                // them with an earlier run in report.txt.
                guard let folder = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput") else { break }
                Task.detached(priority: .userInitiated) {
                    let baseline = defaults.string(forKey: "PluckScreenshotBaseline").map { URL(fileURLWithPath: $0) }
                    LogoAnimation.renderGoldenFrames(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: output), baseline: baseline)
                    await MainActor.run { NSApp.terminate(nil) }
                }
            case "logoprofile":
                // -PluckScreenshotFile <folder> of logos: each one's profile, as JSON lines, to -PluckScreenshotOutput <file>.
                guard let folder = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput") else { break }
                Task.detached(priority: .userInitiated) {
                    LogoAnimation.writeProfiles(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: output))
                    await MainActor.run { NSApp.terminate(nil) }
                }
            case "logodesign":
                // -PluckScreenshotFile <folder> of logos: three designed ideas each, to -PluckScreenshotOutput <folder>.
                guard let folder = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput") else { break }
                Task.detached(priority: .userInitiated) {
                    LogoAnimation.writeDesigns(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: output))
                    await MainActor.run { NSApp.terminate(nil) }
                }
            case "logoedits":
                // -PluckScreenshotFile <folder> of logos: random design edits checked, to -PluckScreenshotOutput <file>.
                guard let folder = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput") else { break }
                Task.detached(priority: .userInitiated) {
                    LogoAnimation.checkEdits(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: output))
                    await MainActor.run { NSApp.terminate(nil) }
                }
            case "logooutputs":
                // -PluckScreenshotFile <folder> of logos: outputs, loop, sound and files checked, into -PluckScreenshotOutput <folder>.
                guard let folder = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput"), let ffmpeg = manager.tool("ffmpeg") else { break }
                Task.detached(priority: .userInitiated) {
                    await LogoAnimation.checkOutputs(from: URL(fileURLWithPath: folder), to: URL(fileURLWithPath: output), ffmpeg: ffmpeg)
                    await MainActor.run { NSApp.terminate(nil) }
                }
            case "brandpackcheck":
                // -PluckScreenshotFile <logo>: Brand Pack with and without a saved design, into -PluckScreenshotOutput <folder>.
                guard let logo = defaults.string(forKey: "PluckScreenshotFile"),
                      let output = defaults.string(forKey: "PluckScreenshotOutput"), let ffmpeg = manager.tool("ffmpeg") else { break }
                Task.detached(priority: .userInitiated) {
                    await LogoAnimation.checkBrandPack(URL(fileURLWithPath: logo), to: URL(fileURLWithPath: output), ffmpeg: ffmpeg)
                    await MainActor.run { NSApp.terminate(nil) }
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
            case "raw":
                // -PluckScreenshotFile <clip>: opened in Raw Player.
                RawPlayerView.openFile = defaults.string(forKey: "PluckScreenshotFile").map { URL(fileURLWithPath: $0) }
                StudioNavigator.shared.open(windowID: "rawPlayer")
            case "offload":
                // -PluckScreenshotOffloadFrom <folder> -PluckScreenshotOffloadTo <a|b>: offloaded at once.
                // -PluckScreenshotOffloadCard <folder>: shown as the only card plugged in.
                if let card = defaults.string(forKey: "PluckScreenshotOffloadCard") { OffloadView.cardsShown = [URL(fileURLWithPath: card)] }
                StudioNavigator.shared.open(windowID: "offload")
                // -PluckScreenshotOffloadCheck <folder>: that copy checked against its MHL.
                // -PluckScreenshotLog <file>: why an offload couldn't start, and each check's result.
                let log = defaults.string(forKey: "PluckScreenshotLog")
                func note(_ line: String) {
                    guard let log else { return }
                    let old = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                    try? (old + line + "\n").write(toFile: log, atomically: true, encoding: .utf8)
                }
                if let folder = defaults.string(forKey: "PluckScreenshotOffloadCheck") {
                    OffloadCenter.shared.check(URL(fileURLWithPath: folder))
                    Task {
                        while let check = OffloadCenter.shared.checks.first, !check.finished { try? await Task.sleep(for: .milliseconds(200)) }
                        if let c = OffloadCenter.shared.checks.first {
                            note("check matched \(c.matched) changed \(c.changed) missing \(c.missing) extra \(c.extra) unchecked \(c.unchecked) problem \(c.problem ?? "-")")
                        }
                    }
                }
                // -PluckScreenshotOffloadRetry YES: the files that couldn't be copied, once more.
                if defaults.bool(forKey: "PluckScreenshotOffloadRetry") {
                    for job in OffloadCenter.shared.jobs where !job.problems.isEmpty { OffloadCenter.shared.retryProblems(job.id) }
                }
                // -PluckScreenshotOffloadResume YES: the unfinished ones carry on.
                if defaults.bool(forKey: "PluckScreenshotOffloadResume") {
                    for job in OffloadCenter.shared.jobs where job.finished == nil { OffloadCenter.shared.resume(job.id) }
                }
                if let from = defaults.string(forKey: "PluckScreenshotOffloadFrom"), let to = defaults.string(forKey: "PluckScreenshotOffloadTo") {
                    Task {
                        let problem = await OffloadCenter.shared.add(source: URL(fileURLWithPath: from),
                                                           roots: to.split(separator: "|").map { URL(fileURLWithPath: String($0)) },
                                                           name: defaults.string(forKey: "PluckScreenshotName") ?? "Card",
                                                           cascade: defaults.bool(forKey: "PluckScreenshotOffloadCascade"),
                                                           eject: defaults.bool(forKey: "PluckScreenshotOffloadEject"))
                        note("add \(problem ?? "ok")")
                    }
                }
            case "fileeditstest":
                // -PluckScreenshotFile <video>, -PluckScreenshotLog <file>: editing a file's project
                // by its own time (cut out, put back, keep only, undo), each step's clips written down.
                Task { await FileEditsSelfTest.run(defaults: defaults) }
            case "deliverytest":
                // Every file in -PluckScreenshotFile <folder> checked for -PluckScreenshotDestination; to -PluckScreenshotLog.
                Task { await DeliveryCheck.selfTest(defaults: defaults) }
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
                StudioNavigator.shared.show(.tools)
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
                // -PluckScreenshotTime <seconds>: the playhead there once it's built.
                if let seconds = Double(defaults.string(forKey: "PluckScreenshotTime") ?? "") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { StudioNavigator.shared.current?.project?.seek(to: seconds) }
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
