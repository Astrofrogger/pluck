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
        OfficeActions.register("shrinkHold") { arguments, _ in
            ShrinkCenter.shared.held = arguments["hold"] as? Bool == true
            return ["held": ShrinkCenter.shared.held]
        }
        OfficeActions.register("shrinkStop") { arguments, _ in
            let id = try OfficeActions.text(arguments["id"], 40)
            if ShrinkCenter.shared.active?.uuidString == id { ShrinkCenter.shared.pause() }
            return ["stopped": true]
        }
    }

    // MARK: Places

    /// A path as a NAS place ("remount\npath"); nil on a disk of this Mac's own.
    nonisolated static func place(_ path: String) -> String? {
        OfficeGroup.place(URL(fileURLWithPath: path)).map { $0.remount + "\n" + $0.path }
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

    static func state(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) -> [String: Any] {
        let center = ShrinkCenter.shared
        var answer: [String: Any] = ["version": 1, "can": mayShrink(admin: OfficeAccess.shared.isAdmin(device), fullTrust: device.allowed.fullTrust,
                                                                      editorHere: OfficeAccess.shared.rights(for: device).render),
                                     "name": Host.current().localizedName ?? "Mac"]
        if let id = arguments["id"] as? String, let run = center.runs.first(where: { $0.id.uuidString == id }) {
            let files = run.files.compactMap { translated($0, place) }
            answer["files"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(files))) ?? []
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
            center.add(here, settings: settings, destination: destination?.map { URL(fileURLWithPath: $0) }, roots: roots, id: id)
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
        merge(files.compactMap { translated($0, local) ?? translatedLoose($0) }, into: id, center: center)
        return answer["working"] as? Bool == true
    }

    /// A finished file whose original moved away (its old path no longer there): only its own path kept as sent.
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
    static func merge(_ files: [ShrinkFolders.File], into id: UUID, center: ShrinkCenter) {
        guard let run = center.run(id) else { return }
        for remote in files where [.done, .skipped, .failed, .restored].contains(remote.state) {
            guard var mine = run.files.first(where: { $0.path == remote.path }), mine.state == .elsewhere || mine.state == .pending else { continue }
            mine.state = remote.state
            mine.note = remote.note
            mine.master = remote.master
            mine.masterSize = remote.masterSize
            mine.moved = remote.moved
            center.set(mine, in: id)
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
            if editing != held, (try? await OfficeRenderClient.shared.ask("shrinkHold", ["hold": editing], timeout: 20)) != nil { held = editing }
            let working = await poll(id, center: center)
            if !working, center.run(id)?.files.contains(where: { $0.state == .elsewhere }) != true { break }
            try? await Task.sleep(for: .seconds(15))
        }
        if held == true { _ = try? await OfficeRenderClient.shared.ask("shrinkHold", ["hold": false], timeout: 20) }
    }
}
