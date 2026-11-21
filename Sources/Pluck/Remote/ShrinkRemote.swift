import Foundation

/// Shrink Folders on the always-on Mac (Edit Anywhere): the same engine (ShrinkCenter) runs there
/// on the files it reaches. Files travel as NAS places (OfficeGroup.place: the share's remount URL
/// and the path in it), never as this Mac's paths; a file the office Mac can't see stays for this
/// Mac. Each file is claimed before it's made (ShrinkCenter), so with "Both" the two Macs never
/// make the same master. Actions: shrinkState, shrinkStart, shrinkStop, shrinkHold (someone edits
/// at the Mac that asked: wait). Admin, Full Trust, or a role that may render in the file's shared folder.
@MainActor
enum ShrinkRemote {
    static func register() {
        OfficeActions.register("shrinkState") { arguments, device in state(arguments, device) }
        OfficeActions.register("shrinkStart") { arguments, device in try start(arguments, device) }
        OfficeActions.register("shrinkHold") { arguments, device in try hold(arguments, device) }
        OfficeActions.register("shrinkStop") { arguments, device in try stop(arguments, device) }
    }

    /// Someone edits at the Mac that asked: wait (for a minute, renewed while it lasts). Only a Mac that may start shrinks here.
    static func hold(_ arguments: [String: Any], _ device: OfficeRenderServer.Device, center given: ShrinkCenter? = nil) throws -> [String: Any] {
        let center = given ?? .shared
        try mayStart(device)
        center.hold(arguments["hold"] as? Bool == true)
        return ["held": center.held]
    }

    /// Stops a run here (and keeps it stopped until it's sent again). Only a Mac that may start shrinks here.
    static func stop(_ arguments: [String: Any], _ device: OfficeRenderServer.Device, center given: ShrinkCenter? = nil) throws -> [String: Any] {
        let center = given ?? .shared
        try mayStart(device)
        let text = try OfficeActions.text(arguments["id"], 40)
        if let id = UUID(uuidString: text) { center.stoppedRemotely.insert(id) }
        if center.active?.uuidString == text { center.pause() }
        return ["stopped": true]
    }

    /// The rights shrinkState says as "can".
    static func mayStart(_ device: OfficeRenderServer.Device) throws {
        guard mayShrink(admin: OfficeAccess.shared.isAdmin(device), fullTrust: device.allowed.fullTrust, editorHere: OfficeAccess.shared.rights(for: device).render)
        else { throw OfficeLink.Failure.office(String(localized: "Needs Admin or Full Trust on the always-on Mac")) }
    }

    // MARK: Places

    /// A path as a NAS place ("remount\npath"); nil on a disk of this Mac's own.
    nonisolated static func place(_ path: String) -> String? {
        OfficeGroup.place(URL(fileURLWithPath: path)).map { $0.remount + "\n" + $0.path }
    }

    /// A path as a NAS place even when nothing is there (any more): the nearest folder that's there looked up,
    /// the rest as text (a moved original, its RED spans, an .mp4 whose master is a .mov are never dropped).
    nonisolated static func placeText(_ path: String, place: (String) -> String? = { ShrinkRemote.place($0) }) -> String? {
        var probe = path, rest = ""
        while !FileManager.default.fileExists(atPath: probe), probe != "/", !probe.isEmpty {
            rest = "/" + (probe as NSString).lastPathComponent + rest
            probe = (probe as NSString).deletingLastPathComponent
        }
        return place(probe).map { $0 + rest }
    }

    /// Where a place is on this Mac (nil: its share isn't mounted here, or it isn't there).
    nonisolated static func local(_ place: String) -> String? {
        let parts = place.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return OfficeGroup.localURL(OfficeGroup.Place(remount: parts[0], path: parts[1], changed: .now))?.path
    }

    /// A file with every path in it changed (nil: one can't be).
    nonisolated static func translated(_ file: ShrinkFolders.File, _ map: (String) -> String?) -> ShrinkFolders.File? {
        var file = file
        guard let path = map(file.path), let folder = map(file.folder) else { return nil }
        file.path = path
        file.folder = folder
        file.parts = file.parts.compactMap(map)
        file.master = file.master.flatMap(map)
        file.moved = file.moved.flatMap(map)
        file.sidecars = file.sidecars?.compactMap(map)
        file.temp = file.temp.flatMap(map)
        // (A second copy somewhere the other Mac can't reach isn't one there.)
        if var copy = file.copied {
            if let folder = map(copy.folder), let target = map(copy.target) { (copy.folder, copy.target) = (folder, target); file.copied = copy } else { file.copied = nil }
        }
        // (Its project too, where its age is looked at; one that can't be: its folder is looked at instead.)
        if !file.project.isEmpty { file.project = map(file.project) ?? "" }
        return file
    }

    // MARK: The office Mac

    /// Who may shrink a file: Admin, Full Trust, or a role that may render where it is.
    nonisolated static func mayShrink(admin: Bool, fullTrust: Bool, editorHere: Bool) -> Bool { admin || fullTrust || editorHere }

    static func may(_ device: OfficeRenderServer.Device, at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let editor = OfficeArchive.shared.folders.first { path.hasPrefix($0.path + "/") }.map { root in
            OfficeActions.allowed(\.render, device, share: (root, OfficeProxies.id(root)), file: url)
        } ?? false
        return mayShrink(admin: OfficeAccess.shared.isAdmin(device), fullTrust: device.allowed.fullTrust, editorHere: editor)
    }

    static func state(_ arguments: [String: Any], _ device: OfficeRenderServer.Device, center given: ShrinkCenter? = nil, run go: Bool = true) -> [String: Any] {
        let center = given ?? .shared
        var answer: [String: Any] = ["version": 1, "can": mayShrink(admin: OfficeAccess.shared.isAdmin(device), fullTrust: device.allowed.fullTrust,
                                                                      editorHere: OfficeAccess.shared.rights(for: device).render),
                                     "name": Host.current().localizedName ?? "Mac"]
        if let id = arguments["id"] as? String, let run = center.runs.first(where: { $0.id.uuidString == id }) {
            let files = run.files.compactMap { translated($0) { placeText($0) } }
            answer["files"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(files))) ?? []
            // Idle with this run still to do (restarted after a quit or power cut, or busy with another run before): it carries on.
            if center.active == nil, answer["can"] as? Bool == true, !center.stoppedRemotely.contains(run.id),
               run.files.contains(where: { $0.state == .pending || $0.state == .working }) {
                answer["resumed"] = true
                if go, let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") {
                    Task { await center.resume(run.id, ffmpeg: ffmpeg, ffprobe: ffprobe) }
                }
            }
            answer["working"] = center.active == run.id
            if center.active == run.id, let left = center.timeLeft { answer["left"] = left }
        }
        return answer
    }

    static func start(_ arguments: [String: Any], _ device: OfficeRenderServer.Device, center given: ShrinkCenter? = nil,
                      run: Bool = true) throws -> [String: Any] {
        let center = given ?? .shared
        guard let id = UUID(uuidString: try OfficeActions.text(arguments["id"], 40)), let sent = arguments["files"],
              let settingsValue = arguments["settings"],
              let files = ShrinkFolders.decodeFiles(sent),
              let settings = try? JSONDecoder().decode(ShrinkFolders.Settings.self, from: JSONSerialization.data(withJSONObject: settingsValue)),
              files.count <= 20_000 else { throw OfficeActions.incomplete() }
        var here: [ShrinkFolders.File] = [], missing: [String] = [], refused = 0
        for file in files {
            guard let mine = translated(file, local) else { missing.append(file.path); continue }
            if may(device, at: mine.path) { here.append(mine) } else { refused += 1; missing.append(file.path) }
        }
        if here.isEmpty, refused > 0 {
            throw OfficeLink.Failure.office(String(localized: "Shrinking folders on the always-on Mac needs Admin or Full Trust there."))
        }
        let destination = (arguments["destination"] as? String).map { local($0) }
        if case .some(nil) = destination { throw OfficeLink.Failure.office(String(localized: "The always-on Mac can’t reach the destination folder.")) }
        let roots = (arguments["roots"] as? [String] ?? []).compactMap(local)
        if !here.isEmpty {
            center.stoppedRemotely.remove(id)
            center.add(here, settings: settings, destination: destination?.map { URL(fileURLWithPath: $0) }, roots: roots, id: id,
                       months: arguments["months"] as? Int)
            // Where the asking Mac wants each project's second copies (a target this Mac can't reach: that Mac makes them).
            let copies = (arguments["copies"] as? [String: String] ?? [:]).reduce(into: [String: String]()) { found, pair in
                if let project = local(pair.key), let target = local(pair.value) { found[project] = target }
            }
            if !copies.isEmpty { center.update(id) { $0.copyTargets = copies } }
            if run, let ffmpeg = AppDelegate.shared?.manager.tool("ffmpeg"), let ffprobe = AppDelegate.shared?.manager.tool("ffprobe") {
                Task { await center.resume(id, ffmpeg: ffmpeg, ffprobe: ffprobe) }
            }
        }
        return ["started": here.count, "missing": missing]
    }

    // MARK: This Mac

    /// Why the always-on Mac can't shrink (nil: it can).
    static func unavailable() async -> String? {
        guard OfficeRenderClient.shared.office != nil else { return String(localized: "Pair an always-on Mac in Edit Anywhere first") }
        do {
            let answer = try await OfficeRenderClient.shared.ask("shrinkState", [:], timeout: 20)
            return answer["can"] as? Bool == true ? nil : String(localized: "Needs Admin or Full Trust on the always-on Mac")
        } catch { return reason(error) }
    }

    /// An error from the office Mac in words (an older one doesn't know the actions).
    nonisolated static func reason(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.contains(String(localized: "The host Mac doesn’t know how to do that.")) || text.contains("doesn’t know how to do that")
            ? String(localized: "The always-on Mac needs a newer Pluck") : text
    }

    /// Sends a run's files to the always-on Mac (`reversed`: from the end, when both Macs share it).
    /// Gives the files it took; the others stay for this Mac.
    static func send(_ run: ShrinkFolders.Run, files: [ShrinkFolders.File], reversed: Bool) async throws -> Set<String> {
        let placed = files.compactMap { file in translated(file, place).map { (file.path, $0) } }
        guard !placed.isEmpty else { return [] }
        var arguments: [String: Any] = ["id": run.id.uuidString,
                                        "files": try JSONSerialization.jsonObject(with: JSONEncoder().encode((reversed ? placed.reversed() : placed).map(\.1))),
                                        "settings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(run.settings)),
                                        "roots": run.roots.compactMap(place)]
        // (An older always-on Mac doesn't know it: it goes by the survey's age.)
        if let months = run.months { arguments["months"] = months }
        // Each project's second copy target, as places (an older always-on Mac doesn't know it: this Mac makes them).
        let rules = ShrinkFolders.Rules.load()
        var copies: [String: String] = [:]
        for file in files where !file.project.isEmpty && copies[file.project] == nil {
            if case .target(let target) = ShrinkFolders.decision(file, rules: rules), let project = place(file.project), let there = place(target) { copies[project] = there }
        }
        if !copies.isEmpty { arguments["copies"] = copies }
        if let destination = run.destination {
            guard let there = place(destination) else { return [] }
            arguments["destination"] = there
        }
        let answer = try await OfficeRenderClient.shared.ask("shrinkStart", arguments, timeout: 60)
        let missing = Set(answer["missing"] as? [String] ?? [])
        return Set(placed.filter { !missing.contains($0.1.path) }.map(\.0))
    }

    /// The always-on Mac's results for a run, into this Mac's copy of it. Gives whether it's still working.
    static func poll(_ id: UUID, center given: ShrinkCenter? = nil) async -> Bool {
        let center = given ?? .shared
        guard let answer = try? await OfficeRenderClient.shared.ask("shrinkState", ["id": id.uuidString], timeout: 20),
              let sent = answer["files"], let files = ShrinkFolders.decodeFiles(sent)
        else { return false }
        merge(files.compactMap(translatedLoose), into: id, center: center)
        return answer["working"] as? Bool == true
    }

    /// A file from the always-on Mac, every path mapped as text against its share's place here (a path that
    /// isn't there any more, as a moved original's, is kept).
    nonisolated static func translatedLoose(_ file: ShrinkFolders.File) -> ShrinkFolders.File? {
        translated(file) { local($0) ?? localPath($0) }
    }

    /// A place's path on this Mac even when nothing is there (yet or any more).
    nonisolated static func localPath(_ place: String) -> String? {
        let parts = place.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let root = local(parts[0] + "\n/") else { return nil }
        return (root as NSString).appendingPathComponent(String(parts[1].drop { $0 == "/" }))
    }

    /// The office Mac's states for files this Mac left to it (or both took): done, skipped and failed count.
    /// Its done counts over anything here but done (this Mac found the file gone or changed: the office Mac
    /// had moved it); the rest only over files this Mac didn't do.
    static func merge(_ files: [ShrinkFolders.File], into id: UUID, center: ShrinkCenter) {
        guard let run = center.run(id) else { return }
        for remote in files where [.done, .skipped, .failed, .restored].contains(remote.state) {
            guard let mine = run.files.first(where: { $0.path == remote.path }) else { continue }
            // A second copy it made of a master this Mac has too: kept here.
            if mine.state == .done, remote.state == .done, mine.copied == nil, let copy = remote.copied, remote.masterHash == mine.masterHash, mine.masterHash != nil {
                var mine = mine
                mine.copied = copy
                center.set(mine, in: id)
                continue
            }
            let open = mine.state == .elsewhere || mine.state == .pending
            guard open || (remote.state == .done && ![.done, .restored, .working].contains(mine.state)) else { continue }
            var remote = remote
            // (An older always-on Mac drops the parts it can't find any more: the clip's parts are the ones this Mac found.)
            if remote.parts.count < mine.parts.count { remote.parts = mine.parts }
            // (Where it belongs is this Mac's own.)
            remote.project = mine.project
            remote.client = mine.client
            remote.projectName = mine.projectName
            center.set(remote, in: id)
        }
    }

    /// While a run is partly on the always-on Mac: its results brought in, and it told to wait while
    /// someone edits here. Ends when it's done there.
    static func follow(_ id: UUID, center given: ShrinkCenter? = nil) async {
        let center = given ?? .shared
        var held: Bool?
        while !Task.isCancelled {
            let folder = center.run(id)?.roots.first ?? "/"
            let now = await center.editing(folder)
            let editing = !center.runAnyway && (center.waitingForEdit || now)
            // (A hold runs out there after a minute: renewed each look while editing goes on.)
            if editing != held || editing, (try? await OfficeRenderClient.shared.ask("shrinkHold", ["hold": editing], timeout: 20)) != nil { held = editing }
            let working = await poll(id, center: center)
            if !working, center.run(id)?.files.contains(where: { $0.state == .elsewhere }) != true { break }
            try? await Task.sleep(for: .seconds(15))
        }
        if held == true { _ = try? await OfficeRenderClient.shared.ask("shrinkHold", ["hold": false], timeout: 20) }
        // (Its proxies wait until the office Mac is done with the project too.)
        center.wrapUp(id)
    }
}
