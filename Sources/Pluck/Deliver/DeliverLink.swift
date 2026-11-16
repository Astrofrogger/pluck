import Foundation

/// Runs the `pluck-review` helper (§5) while at least one share link is live: JSON lines both ways,
/// the first stdin line its settings, `rooms` again whenever links change. Restarted with a backoff
/// (2, 5, 15, 60 s) when it exits; quit when no link is live.
@MainActor
@Observable
final class DeliverLink {
    static let shared = DeliverLink(server: .shared)

    let server: DeliverServer
    private(set) var running = false
    private(set) var version: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var restart: Task<Void, Never>?
    /// Tests: settings merged into the first line ({"signal":"ws://127.0.0.1:8787/signal","local":true}).
    @ObservationIgnored var testSettings: [String: Any]?

    nonisolated static let signal = "wss://pluck.tools/signal"
    nonisolated static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/pluck-review") }

    init(server: DeliverServer) {
        self.server = server
    }

    /// Wires the server to the helper and starts it if a link is live (at launch).
    func start() {
        server.output = { [weak self] in self?.write($0) }
        server.notify = { item, name in
            let number = DeliverStore.shared.find(item.asset)?.asset.versions.first { $0.id == item.version }?.number
            DeliverNotify.post(item, assetName: name, versionNumber: number)
        }
        server.markMaker = { DeliverCopies.shared.enqueueMark(asset: $0, version: $1, link: $2) }
        server.store.listeners.append { [weak self] event in
            if case .linksChanged = event { self?.update() }
        }
        update()
        Task { await eraseOldRooms() } // "Make a New Link" while offline: the old rooms still to erase
        server.store.trimAllActivity() // the retention setting (R8), also for links nobody opens any more
        // §13: the data host's sync, deadlines, watched render folders and host updates.
        DeliverSync.shared.resume()
        DeliverDeadlines.shared.start()
        DeliverWatch.shared.start()
        DeliverHostUpdate.shared.start()
    }

    /// R11: deletes what pluck.tools keeps for the link's room (it proves the room's reg key, like a register), then the
    /// link and its data here. Straight from Swift, so it works whether or not the helper is running.
    func deleteLink(_ id: UUID) async {
        let store = server.store
        if let link = store.link(id), let secret = store.secret(id) {
            let local = testSettings?["local"] as? Bool == true
            if ScreenshotMode.scene == nil || local { // test copies never reach pluck.tools
                _ = await Self.erase(room: link.roomID, reg: DeliverKeys.registerKey(root: secret), expires: link.expires, signal: testSettings?["signal"] as? String ?? Self.signal)
            }
        }
        store.deleteLink(id)
    }

    /// "Make a New Link" (§13.24 L2): the link gets its new key at once, and its old room is erased on pluck.tools with
    /// the old reg (only a tombstone stays, so whoever has the old address can't take that room). The old reg is kept,
    /// in the keychain, until the erase is answered, so a Mac that's offline now erases it later.
    func renew(_ id: UUID) {
        let store = server.store
        guard let link = store.link(id), let secret = store.secret(id) else { return }
        var pending = UserDefaults.standard.stringArray(forKey: Self.eraseKey) ?? []
        DeliverKeychain.save(Data(DeliverKeys.registerKey(root: secret).utf8), as: "erase/\(link.roomID)")
        if let expires = link.expires { UserDefaults.standard.set(expires, forKey: Self.eraseKey + link.roomID) }
        pending.append(link.roomID)
        UserDefaults.standard.set(pending, forKey: Self.eraseKey)
        store.renew(id)
        Task { await eraseOldRooms() }
    }

    nonisolated static let eraseKey = "reviewRoomsToErase"

    /// The old rooms of renewed links: erased (or found to be someone else's, so nothing of ours is there) are done.
    func eraseOldRooms() async {
        if ScreenshotMode.scene != nil, testSettings?["local"] as? Bool != true { return } // test copies never reach pluck.tools
        let signal = testSettings?["signal"] as? String ?? Self.signal
        for room in UserDefaults.standard.stringArray(forKey: Self.eraseKey) ?? [] {
            guard let reg = DeliverKeychain.load("erase/\(room)").map({ String(decoding: $0, as: UTF8.self) }) else { forgetErase(room); continue }
            if await Self.erase(room: room, reg: reg, expires: UserDefaults.standard.object(forKey: Self.eraseKey + room) as? Date, signal: signal) != nil {
                forgetErase(room)
            }
        }
    }

    private func forgetErase(_ room: String) {
        UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: Self.eraseKey) ?? []).filter { $0 != room }, forKey: Self.eraseKey)
        UserDefaults.standard.removeObject(forKey: Self.eraseKey + room)
        DeliverKeychain.delete("erase/\(room)")
    }

    /// `{"t":"erase","v":2,"reg","expires"?}` to `<signal>/<room>` (no Origin, so the Room takes it for a Mac). True on
    /// `erased`, false on `taken` (the room isn't ours, so nothing of ours is there), nil when it didn't get through
    /// (offline, or `rate`). `expires`: how long the Room keeps its tombstone (none: a year).
    nonisolated static func erase(room: String, reg: String, expires: Date? = nil, signal: String) async -> Bool? {
        var message: [String: Any] = ["t": "erase", "v": 2, "reg": reg]
        if let expires { message["expires"] = ISO8601DateFormatter().string(from: expires) }
        guard let url = URL(string: "\(signal)/\(room)"),
              let body = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                guard (try? await task.send(.string(String(decoding: body, as: UTF8.self)))) != nil else { return nil }
                while let message = try? await task.receive() {
                    guard case .string(let text) = message,
                          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                    if json["t"] as? String == "erased" { return true }
                    if json["t"] as? String == "error" { return json["code"] as? String == "taken" ? false : nil }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The rooms of live links whose keys are kept.
    var rooms: [[String: String]] {
        server.store.links.filter(\.isLive).compactMap { link in
            guard let key = server.store.key(link.id), let secret = server.store.secret(link.id) else { return nil }
            var room = ["room": link.roomID, "reg": DeliverKeys.registerKey(root: secret), "join": DeliverKeys.joinHash(key)]
            if let expires = link.expires { room["expires"] = ISO8601DateFormatter().string(from: expires) } // the Room's tombstone (§13.24)
            return room
        }
    }

    func update() {
        let rooms = rooms
        if rooms.isEmpty { return stop() }
        if process == nil { launch() } else { write(["rooms": rooms]) }
    }

    private func launch() {
        // Test copies never reach pluck.tools: only with their own local settings.
        if ScreenshotMode.scene != nil, testSettings?["local"] as? Bool != true { return }
        guard FileManager.default.isExecutableFile(atPath: Self.helper.path) else { return }
        let process = Process()
        process.executableURL = Self.helper
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in Task { @MainActor in self?.ended(ended) } }
        // A helper that died fails the write instead of ending Pluck.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard (try? process.run()) != nil else { return }
        self.process = process
        input = stdin.fileHandleForWriting
        running = true
        var settings: [String: Any] = ["signal": Self.signal, "stun": ["stun.cloudflare.com:3478"],
                                       "rooms": rooms, "maxPeers": 20, "local": false]
        settings.merge(DeliverRelay.shared.settings) { $1 }
        settings.merge(testSettings ?? [:]) { $1 }
        write(settings)
        let buffer = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            for line in buffer.add(chunk) {
                guard let report = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                Task { @MainActor in self?.heard(report, from: process) }
            }
        }
    }

    private func heard(_ report: [String: Any], from sender: Process) {
        guard sender === process else { return }
        if let ready = report["ready"] as? [String: Any] {
            version = ready["version"] as? String
            restarts = 0
        }
        DeliverRelay.shared.heard(report)
        server.helper(report)
    }

    private func write(_ line: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: line) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    private func ended(_ ended: Process) {
        guard ended === process else { return }
        process = nil
        input = nil
        running = false
        for peer in server.peers.keys { server.helper(["peer": ["peer": peer, "state": "closed"]]) }
        guard !rooms.isEmpty else { return }
        let wait = [2, 5, 15, 60][min(restarts, 3)]
        restarts += 1
        restart = Task {
            try? await Task.sleep(for: .seconds(wait))
            if process == nil { update() }
        }
    }

    func stop() {
        restart?.cancel()
        try? input?.close()
        let old = process
        process = nil
        input = nil
        running = false
        old?.terminate()
    }
}

/// Splits a pipe's bytes into lines (used on the handle's own queue, one chunk at a time).
final class LineReader: @unchecked Sendable {
    private var data = Data()

    func add(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let end = data.firstIndex(of: 0x0A) {
            lines.append(Data(data[data.startIndex..<end]))
            data.removeSubrange(data.startIndex...end)
        }
        return lines
    }
}
