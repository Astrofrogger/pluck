import CryptoKit
import Foundation
import Network

extension PhotoSelfTest {
    /// Edit Anywhere over a slow, far link (-PluckScreenshotOnly remotelink): many questions on one kept connection,
    /// each still checked on its own; Macs and hosts from before (one question per connection) both ways; the
    /// streaming proxies' choice and the too-slow advice; and the drive's speed before and after over SlowLink
    /// (30 Mbit/s, 100 ms round trip, a handshake and slow start per new connection).
    static func remoteLinkTest() async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteLinkTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let size = 32 << 20
        fm.createFile(atPath: base.appendingPathComponent("speed.bin").path, contents: OfficeLink.randomBytes(size))

        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        archive.add(base)
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        let saved = (RemoteDriveBlocks.maxFetches, RemoteDriveBlocks.ahead)
        defer {
            client.keepsConnections = true
            server.keepsConnections = true
            (RemoteDriveBlocks.maxFetches, RemoteDriveBlocks.ahead) = saved
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(base)
            server.stop()
            RemoteDriveBlocks.trim(to: 0)
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("link: pairing code", false, server.problem ?? "") }
        do { try await client.pair(.address("127.0.0.1"), code: code) } catch { return check("link: paired", false, error.localizedDescription) }
        guard let office = client.office, let device = server.devices.first else { return check("link: paired", false) }
        server.setRights(.init(browse: true, proxies: true, originals: true, render: true), for: device.id)
        client.useOnly("127.0.0.1")
        let keys = OfficeLink.keys(office.secret), id = OfficeLink.uuidData(office.device)

        // Raw questions, as a Mac of either kind sends them.
        func question(keep: Bool, nonce: Data = OfficeLink.randomBytes(16)) -> (frame: Data, nonce: Data) {
            var message: [String: Any] = ["action": "jobs", "args": [String: Any](), "time": Date.now.timeIntervalSince1970, "nonce": nonce.base64EncodedString()]
            if keep { message["keep"] = true }
            let sealed = try! ChaChaPoly.seal(try! JSONSerialization.data(withJSONObject: message), using: keys.request, authenticating: id)
            return (OfficeLink.frame(.request, id + sealed.combined), nonce)
        }
        func answer(_ reply: (kind: OfficeLink.Kind, payload: Data)?, _ nonce: Data) -> [String: Any]? {
            guard let reply, let box = try? ChaChaPoly.SealedBox(combined: reply.payload),
                  let plain = try? ChaChaPoly.open(box, using: keys.answer, authenticating: nonce) else { return nil }
            return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
        }
        func connect() async -> NWConnection? {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: OfficeLink.listenPort)!, using: .tcp)
            connection.start(queue: .global())
            for _ in 0..<100 where connection.state != .ready { try? await Task.sleep(for: .milliseconds(20)) }
            return connection.state == .ready ? connection : nil
        }
        func read(_ connection: NWConnection, timeout: TimeInterval = 10) async -> (kind: OfficeLink.Kind, payload: Data)? {
            await withCheckedContinuation { done in
                FrameReader.read(from: connection, limit: OfficeLink.maxAnswer, timeout: timeout) { done.resume(returning: $0) }
            }
        }
        /// Whether the other end closed (or nothing more comes within a couple of seconds: false).
        func closed(_ connection: NWConnection) async -> Bool {
            await withCheckedContinuation { done in
                let once = OnceFlag()
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, complete, error in
                    if once.claim() { done.resume(returning: complete || error != nil || data == nil) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if once.claim() { done.resume(returning: false) } }
            }
        }

        // Three questions sent at once on one connection: three answers, in order, each kept.
        if let connection = await connect() {
            let asked = (0..<3).map { _ in question(keep: true) }
            for one in asked { connection.send(content: one.frame, completion: .contentProcessed { _ in }) }
            var answers: [[String: Any]?] = []
            for one in asked { answers.append(answer(await read(connection), one.nonce)) }
            check("link: many questions on one connection, answered in order", answers.allSatisfy { $0?["jobs"] != nil && $0?["keep"] as? Bool == true },
                  "\(answers.map { $0?.keys.sorted() ?? [] })")
            // Each question on it is still checked: one seen before closes it, unanswered.
            connection.send(content: question(keep: true, nonce: asked[0].nonce).frame, completion: .contentProcessed { _ in })
            check("link: a replayed question on a kept connection is refused", await read(connection, timeout: 5) == nil)
            connection.cancel()
        } else { check("link: raw connection", false) }

        // A Mac from before (no "keep"): its answer, then the host closes, as always.
        if let connection = await connect() {
            let one = question(keep: false)
            connection.send(content: one.frame, completion: .contentProcessed { _ in })
            let reply = answer(await read(connection), one.nonce)
            let ended = await closed(connection)
            check("link: a Mac from before gets one answer, then the connection closes", reply?["jobs"] != nil && reply?["keep"] == nil && ended)
            connection.cancel()
        } else { check("link: raw connection", false) }

        // This client: answers come on one kept connection.
        do {
            for _ in 0..<3 { _ = try await client.ask("jobs") }
            check("link: the client keeps one connection for its questions", client.keptConnections == 1, "\(client.keptConnections)")
            // The host closed it meanwhile (sharing stopped and started again): asked again on a new one.
            server.stop()
            // (The port is free again a moment after its listener goes.)
            try? await Task.sleep(for: .seconds(1))
            server.start()
            for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            check("link: a kept connection the host closed is replaced", (try await client.ask("jobs"))["jobs"] != nil && client.keptConnections == 1)
        } catch { check("link: kept questions", false, error.localizedDescription) }

        // A host from before (it never keeps): every question still answered, nothing kept.
        do {
            server.keepsConnections = false
            client.useOnly("127.0.0.1")
            for _ in 0..<3 { _ = try await client.ask("jobs") }
            let piece = try await client.fileData(share: OfficeProxies.id(base), path: "speed.bin", kind: .original, offset: 5, length: 100)
            check("link: a host from before answers one question per connection", client.keptConnections == 0 && piece.data.count == 100, "\(client.keptConnections)")
            server.keepsConnections = true
        } catch { check("link: host from before", false, error.localizedDescription) }

        // Lighter proxies asked for only for clips read: collected, each once, put back when the host didn't take them.
        let choice = RemoteStreamChoice()
        let wanted = choice.wants("a"), again = choice.wants("a"), meanwhile = choice.wants("b")
        let batch = choice.take(200).sorted()
        choice.asked(["a"], ok: true)
        choice.asked(["b"], ok: false)
        let askedAgain = choice.wants("a"), retried = choice.wants("c")
        let done = choice.take(200).sorted(), over = choice.take(200)
        check("link: lighter proxies only for clips read, in batches, again after a failure",
              wanted && !again && !meanwhile && batch == ["a", "b"] && !askedAgain && retried && done == ["b", "c"] && over.isEmpty,
              "\(wanted) \(again) \(meanwhile) \(batch) \(done)")

        // A batch the host refuses is split down to single clips; one refused three times is dropped for the mount.
        let poisoned = RemoteStreamChoice()
        poisoned.lighter = .stream
        var made: Set<String> = [], tries = 0
        for path in ["a", "b", "bad", "c"] { _ = poisoned.wants(path) }
        for _ in 0..<4 {
            _ = poisoned.wants("a")
            await RemoteNetwork.askLighter(share: "s", choice: poisoned, wait: .zero) { paths, _ in
                tries += 1
                if paths.contains("bad") { throw OfficeLink.Failure.office("No such clip") }
                made.formUnion(paths)
            }
        }
        check("link: a refused batch is split, and a clip refused three times is dropped",
              made == ["a", "b", "c"] && !poisoned.wants("bad") && poisoned.take(200).isEmpty, "\(made.sorted()) \(tries) tries")

        // Only questions that read go on a kept connection and are asked again: one that changes something never runs twice.
        let retryable = OfficeRenderClient.retryable
        check("link: only read-only questions are asked again on a fresh connection",
              ["fileData", "jobs", "shares", "driveInfo", "status"].allSatisfy(retryable.contains)
              && !["render", "cancel", "shareProxyMake", "proxyMake", "shareWatch", "resolveRender", "resolveCancel", "send", "reviewAdd"].contains(where: retryable.contains)
              && OfficeRenderClient.keptFirstAnswer <= 10)

        // The streaming proxies' choice and the advice.
        let light = OfficeProxies.Format.light
        check("link: streaming proxies only when the link is too slow for Light, and the host makes them",
              RemoteNetwork.streamFormat(chosen: light, speed: 1.2e6, hostMakes: true) == .stream
              && RemoteNetwork.streamFormat(chosen: light, speed: 2.2e6, hostMakes: true) == .light
              && RemoteNetwork.streamFormat(chosen: light, speed: 1.2e6, hostMakes: false) == .light
              && RemoteNetwork.streamFormat(chosen: light, speed: nil, hostMakes: true) == .light
              && RemoteNetwork.streamFormat(chosen: .prores, speed: 1e6, hostMakes: true) == .prores
              && RemoteNetwork.streamFormat(chosen: .prores, speed: 9e6, hostMakes: true) == .prores)
        // Stand-ins only at mount: a refresh keeps each path's format, whatever the host made meanwhile.
        func entry(_ path: String, _ size: Int64) -> RemoteManifestEntry {
            RemoteManifestEntry(share: "s", path: path, proxy: path, reel: path, size: size, checksum: nil)
        }
        let chosen = [entry("a", 100), entry("b", 100)]
        let mounted = RemoteNetwork.standIns(chosen: chosen, lighter: [entry("a", 40)], standingIn: nil)
        let refreshed = RemoteNetwork.standIns(chosen: chosen, lighter: [entry("a", 40), entry("b", 40)],
                                               standingIn: Set(mounted.standIns.map(\.path)))
        check("link: stand-ins are picked at mount only, a refresh never changes a path's file",
              mounted.entries.map(\.size) == [40, 100] && mounted.standIns.map(\.path) == ["a"]
              && refreshed.entries.map(\.size) == [40, 100] && refreshed.standIns.map(\.path) == ["a"],
              "\(mounted.entries.map(\.size)) \(refreshed.entries.map(\.size))")
        let slow = RemoteNetwork.tooSlow(speed: 1e6, format: light, downloadBytes: 600_000_000)
        check("link: too slow says the speed and the download's time", slow?.contains("1 MB/s") == true && slow?.contains("10") == true, slow ?? "nil")
        check("link: no advice when the link plays the proxies", RemoteNetwork.tooSlow(speed: 2.2e6, format: light, downloadBytes: 1) == nil
              && RemoteNetwork.tooSlow(speed: 1e6, format: .stream, downloadBytes: 1) == nil)
        check("link: streaming proxies are made at 720p, named like the others", OfficeProxies.Format.made.contains(.stream)
              && OfficeProxies.Format.stream.height == 720 && OfficeProxies.proxyName("Day 1/A001.MXF", clashes: false) == "Day 1/A001.mov")

        // The drive over 30 Mbit/s and 100 ms: before (a connection per piece, four at once), kept connections alone, and both.
        guard let link = SlowLink(to: OfficeLink.listenPort, bitsPerSecond: 30e6, roundTrip: 0.1) else { return check("link: slow link", false) }
        for _ in 0..<100 where link.port == nil { try? await Task.sleep(for: .milliseconds(20)) }
        guard let port = link.port else { return check("link: slow link", false) }
        defer { link.stop() }
        let share = OfficeProxies.id(base)
        func speed(keep: Bool, fetches: Int, ahead: Int) async -> Double {
            client.keepsConnections = keep
            server.keepsConnections = keep
            (RemoteDriveBlocks.maxFetches, RemoteDriveBlocks.ahead) = (fetches, ahead)
            client.useOnly("127.0.0.1:\(port)")
            let drive = RemoteShareDrive(cacheKey: "link-\(UUID().uuidString)") { entry, offset, length in
                try await client.fileData(share: share, path: entry.path, kind: .original, offset: offset, length: length).data
            }
            let entry = RemoteManifestEntry(share: share, path: "speed.bin", proxy: "speed.bin", reel: "speed", size: Int64(size), checksum: UUID().uuidString)
            drive.update(RemoteManifest(host: "h", hostName: "Host", share: share, shareName: "Share", entries: [entry]))
            let started = Date.now
            var offset: Int64 = 0
            // As Resolve reads a clip through the drive: in order, a megabyte at a time.
            while offset < Int64(size) {
                guard let piece = try? await drive.blocks.read(entry, offset: offset, count: 1 << 20), !piece.isEmpty else { return 0 }
                offset += Int64(piece.count)
            }
            RemoteDriveBlocks.trim(to: 0)
            return Double(size) / Date.now.timeIntervalSince(started)
        }
        // The speed Stream shows (RemoteNetwork.measure: the first two blocks). Before: one after the other, each on a new connection.
        client.keepsConnections = false
        server.keepsConnections = false
        client.useOnly("127.0.0.1:\(port)")
        var started = Date.now
        for block in 0..<2 { _ = try? await client.fileData(share: share, path: "speed.bin", kind: .original, offset: Int64(block << 22), length: 4 << 20) }
        let shownBefore = Double(8 << 20) / Date.now.timeIntervalSince(started)
        client.keepsConnections = true
        server.keepsConnections = true
        _ = try? await client.ask("jobs")
        let measured = RemoteShareDrive(cacheKey: "link-\(UUID().uuidString)") { entry, offset, length in
            try await client.fileData(share: share, path: entry.path, kind: .original, offset: offset, length: length).data
        }
        let first = RemoteManifestEntry(share: share, path: "speed.bin", proxy: "speed.bin", reel: "speed", size: Int64(size), checksum: UUID().uuidString)
        started = Date.now
        let both = try? await measured.blocks.read(first, offset: 0, count: 8 << 20)
        let shownAfter = both?.count == 8 << 20 ? Double(8 << 20) / Date.now.timeIntervalSince(started) : 0
        RemoteDriveBlocks.trim(to: 0)
        // A preview in the browser (RemoteStream: 2 MB blocks, the next ones read ahead), 16 MB in order.
        func preview(keep: Bool) async -> Double {
            client.keepsConnections = keep
            server.keepsConnections = keep
            client.useOnly("127.0.0.1:\(port)")
            let stream = RemoteStream(contentType: "public.data") { offset, length in
                try await client.fileData(share: share, path: "speed.bin", kind: .original, offset: offset, length: length)
            }
            let started = Date.now
            var offset: Int64 = 0
            while offset < 16 << 20 {
                guard let piece = try? await stream.bytes(offset, 1 << 20), !piece.isEmpty else { return 0 }
                offset += Int64(piece.count)
            }
            return Double(16 << 20) / Date.now.timeIntervalSince(started)
        }
        let previewBefore = await preview(keep: false), previewAfter = await preview(keep: true)
        let before = await speed(keep: false, fetches: 4, ahead: 3)
        let keptOnly = await speed(keep: true, fetches: 4, ahead: 3)
        let after = await speed(keep: true, fetches: 8, ahead: 6)
        let mb = { (rate: Double) in String(format: "%.2f MB/s", rate / 1e6) }
        note("link at 30 Mbit/s (3.75 MB/s), 100 ms: reading a clip: before \(mb(before)), kept connections \(mb(keptOnly)), kept + 8 in flight \(mb(after)); "
             + "the speed shown: before \(mb(shownBefore)), after \(mb(shownAfter)); a preview: before \(mb(previewBefore)), after \(mb(previewAfter))")
        check("link: a preview streams faster on kept connections", previewBefore > 0 && previewAfter > previewBefore * 1.2,
              "before \(mb(previewBefore)), after \(mb(previewAfter))")
        check("link: reading a clip fills most of a slow, far link", before > 0 && after >= before && after > 3.0e6,
              "before \(mb(before)), kept \(mb(keptOnly)), after \(mb(after))")
        check("link: the speed shown is the link's, not one fresh connection's", shownBefore > 0 && shownAfter > shownBefore * 1.2,
              "before \(mb(shownBefore)), after \(mb(shownAfter))")
    }
}

/// A slow, far link between this Mac and itself, for the speed test (no Network Link Conditioner or root needed): each
/// direction shares one rate cap, every byte takes half the round trip, a new connection waits a round trip for its
/// handshake, and each connection starts slow (TCP's window of ten segments, doubling every round trip, back to ten
/// after a second idle).
final class SlowLink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "be.wideopen.pluck.slow-link")
    private let listener: NWListener
    private let rate: Double, oneWay: Double
    /// When each direction's link is free again (0: to the host, 1: from it).
    private var free: [Double] = [0, 0]
    private static let initialWindow = 14_600

    private final class Pipe {
        let from: NWConnection, to: NWConnection, direction: Int
        var buffer = Data()
        var window = SlowLink.initialWindow
        var roundStart: Double
        var roundSent = 0
        var lastSent = 0.0
        var lastArrival = 0.0
        var scheduled = false, ended = false, closed = false
        init(from: NWConnection, to: NWConnection, direction: Int, opens: Double) {
            self.from = from
            self.to = to
            self.direction = direction
            roundStart = opens
        }
    }

    /// (Nil until it's listening: the port it was given.)
    var port: UInt16? { listener.port.map(\.rawValue).flatMap { $0 == 0 ? nil : $0 } }

    init?(to target: UInt16, bitsPerSecond: Double, roundTrip: Double) {
        guard let listener = try? NWListener(using: .tcp, on: .any), let targetPort = NWEndpoint.Port(rawValue: target) else { return nil }
        self.listener = listener
        rate = bitsPerSecond / 8
        oneWay = roundTrip / 2
        listener.newConnectionHandler = { [unowned self] inbound in
            let outbound = NWConnection(host: "127.0.0.1", port: targetPort, using: .tcp)
            let opens = Self.now()
            let up = Pipe(from: inbound, to: outbound, direction: 0, opens: opens), down = Pipe(from: outbound, to: inbound, direction: 1, opens: opens)
            inbound.start(queue: queue)
            outbound.start(queue: queue)
            // The client's first bytes can't leave before its handshake is done.
            queue.asyncAfter(deadline: .now() + oneWay * 2) { [self] in pump(up); pump(down) }
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    private func pump(_ pipe: Pipe) {
        pipe.from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, complete, error in
            if let data, !data.isEmpty { pipe.buffer.append(data) }
            if complete || error != nil { pipe.ended = true }
            send(pipe)
            if !pipe.ended { pump(pipe) }
        }
    }

    /// Sends what the pipe holds, as far as this round's window and the shared link allow, then waits for the next.
    private func send(_ pipe: Pipe) {
        guard !pipe.scheduled, !pipe.closed else { return }
        let now = Self.now()
        if pipe.buffer.isEmpty {
            guard pipe.ended else { return }
            pipe.closed = true
            let to = pipe.to
            // (Just after the last bytes go: a cancel would drop sends still queued, and an end before them cuts them off.)
            queue.asyncAfter(deadline: .now() + max(0, pipe.lastArrival - now) + 0.005) {
                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in to.cancel() })
            }
            return
        }
        if now - pipe.lastSent > 1 { pipe.window = Self.initialWindow }
        if now >= pipe.roundStart + oneWay * 2 {
            // A new round trip: the acks of the last one are back, the window doubles (no losses here).
            if pipe.roundSent > 0 { pipe.window = min(pipe.window * 2, 64 << 20) }
            pipe.roundStart = now
            pipe.roundSent = 0
        }
        let room = pipe.window - pipe.roundSent
        let wait = room <= 0 ? pipe.roundStart + oneWay * 2 - now : max(0, free[pipe.direction] - now)
        if wait > 0.000_5 {
            pipe.scheduled = true
            queue.asyncAfter(deadline: .now() + wait) { [self] in
                pipe.scheduled = false
                send(pipe)
            }
            return
        }
        let count = min(room, pipe.buffer.count, 256 << 10)
        let chunk = pipe.buffer.prefix(count)
        pipe.buffer.removeFirst(count)
        pipe.roundSent += count
        pipe.lastSent = now
        free[pipe.direction] = max(now, free[pipe.direction]) + Double(count) / rate
        let arrival = free[pipe.direction] + oneWay
        pipe.lastArrival = arrival
        let to = pipe.to
        queue.asyncAfter(deadline: .now() + (arrival - now)) { to.send(content: Data(chunk), completion: .contentProcessed { _ in }) }
        send(pipe)
    }
}
