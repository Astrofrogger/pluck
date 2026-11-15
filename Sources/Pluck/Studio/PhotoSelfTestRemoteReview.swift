import AVFoundation

extension PhotoSelfTest {
    /// Review and streaming (-PluckScreenshotOnly remotereview): a host and a client in this test
    /// copy over this Mac. Streamed ranges equal the file's bytes (share files and a render
    /// preview), comments add/reply/resolve and persist, the Library server's review pages need a
    /// session and escape what people typed, and the Resolve marker file has Resolve's layout.
    static func remoteReviewTest() async {
        let fm = FileManager.default
        UserDefaults.standard.set(Int.random(in: 47_900...48_900), forKey: "PluckScreenshotPort")
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("RemoteReviewTest-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Share", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let bytes = OfficeLink.randomBytes((5 << 20) + 4_321)
        fm.createFile(atPath: root.appendingPathComponent("clip.mov").path, contents: bytes)
        let previewBytes = OfficeLink.randomBytes((3 << 20) + 77)
        let previewFile = base.appendingPathComponent("preview.mp4")
        fm.createFile(atPath: previewFile.path, contents: previewBytes)

        let server = OfficeRenderServer.shared, client = OfficeRenderClient.shared, archive = OfficeArchive.shared
        archive.add(root)
        archive.stop()
        server.start()
        for _ in 0..<100 where !server.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        var jobs: [UUID] = []
        defer {
            client.forget()
            for device in server.devices { server.remove(device) }
            archive.remove(root)
            server.stop()
            RemoteReview.testJobs = []
            for id in jobs { try? fm.removeItem(at: RemoteReview.folder.appendingPathComponent(id.uuidString + ".json")) }
            UserDefaults.standard.removeObject(forKey: "PluckScreenshotPort")
        }
        server.startPairing()
        guard let code = server.pairing?.code else { return check("review: pairing code", false, server.problem ?? "") }
        do {
            try await client.pair(.address("127.0.0.1"), code: code)
        } catch {
            return check("review: paired over this Mac", false, error.localizedDescription)
        }
        guard let device = server.devices.first else { return check("review: paired over this Mac", false, "no device") }
        func refused(_ work: () async throws -> Void) async -> Bool {
            do { try await work(); return false } catch { return true }
        }

        // Audit fixes. Resolve's project list and project switch need the render right.
        server.setRights(.init(browse: true, proxies: true, originals: true, render: false), for: device.id)
        func deniedByRights(_ action: String, _ arguments: [String: Any]) async -> Bool {
            do { _ = try await client.ask(action, arguments); return false } catch { return error.localizedDescription.contains("doesn’t allow this Mac") }
        }
        let noList = await deniedByRights("projects", [:])
        let noSwitch = await deniedByRights("project", ["name": "Other", "folder": ""])
        check("audit: project and projects need the render right", noList && noSwitch)
        // The inbox never becomes shared content: no share around it, nothing in it through a share.
        let inbox = OfficeInbox.shared.folder, around = inbox.deletingLastPathComponent()
        try? fm.createDirectory(at: inbox.appendingPathComponent("Mac A", isDirectory: true), withIntermediateDirectories: true)
        fm.createFile(atPath: inbox.appendingPathComponent("Mac A/sent.mov").path, contents: Data(count: 10))
        let addedAround = archive.add(around), addedInside = archive.add(inbox.appendingPathComponent("Mac A", isDirectory: true))
        let listed = ((try? RemoteEditHost.list(around, in: around)) ?? []).compactMap { $0["name"] as? String }
        check("audit: a share can't hold the inbox, and the inbox isn't listed or served", !addedAround && !addedInside
              && !archive.folders.contains(around) && !listed.contains(inbox.lastPathComponent)
              && (try? RemoteEditHost.resolve(inbox.lastPathComponent + "/Mac A/sent.mov", in: around)) == nil
              && (try? RemoteEditHost.resolve("clip.mov", in: root)) != nil, "\(listed)")
        // Each Mac's share of the inbox, and space left free on the host.
        let quota = OfficeInbox.quota
        OfficeInbox.quota = 50
        var full = false
        do { _ = try OfficeInbox.shared.receive("big.bin", size: 100, modified: 0, offset: 0, data: Data(count: 10), from: "Mac Q") } catch { full = (error as? OfficeInbox.Problem) == .full }
        OfficeInbox.quota = quota
        let floor = OfficeInbox.freeFloor
        OfficeInbox.freeFloor = Int64.max / 2
        var noSpace = false
        do { _ = try OfficeInbox.shared.receive("small.bin", size: 10, modified: 0, offset: 0, data: Data(count: 10), from: "Mac Q") } catch { noSpace = (error as? OfficeInbox.Problem) == .noSpace }
        OfficeInbox.freeFloor = floor
        check("audit: the inbox has a per-Mac quota and a free-space floor", full && noSpace)
        try? fm.removeItem(at: inbox)
        // Tailscale: only invited nodes are touched, paired ones by address, never-paired ones go after the invitation.
        let now = Date.now, old = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200)), fresh = ISO8601DateFormatter().string(from: now)
        let tag = PrivateNetwork.Account.inviteeTag
        let nodes: [[String: Any]] = [
            ["id": "paired", "tags": [tag], "addresses": ["100.64.0.2"], "created": old],
            ["id": "pairedKept", "tags": [tag], "addresses": ["100.64.0.3"], "created": old, "keyExpiryDisabled": true],
            ["id": "stray", "tags": [tag], "addresses": ["100.64.0.4"], "created": old],
            ["id": "joining", "tags": [tag], "addresses": ["100.64.0.5"], "created": fresh],
            ["id": "removed", "tags": [tag], "addresses": ["100.64.0.6"], "created": fresh],
            ["id": "pluck-named", "hostname": "pluck-x", "addresses": ["100.64.0.7"], "created": old]]
        let plan = PrivateNetwork.Account.plan(nodes, paired: ["100.64.0.2", "100.64.0.3"], removed: ["100.64.0.6"], now: now, lifetime: 3600)
        check("audit: tailnet nodes kept by recorded address, strays deleted, others untouched",
              plan.map(\.0) == ["paired", "stray", "removed"] && plan.map(\.1) == [.keep, .delete, .delete]
              && PrivateNetwork.Account.aclSnippet.contains("\"tag:pluck-office:\(OfficeLink.port)\""), "\(plan)")

        // Streaming: ranges anywhere (inside a block, across blocks, the tail, past the end) and the whole file.
        server.setRights(.init(browse: true, proxies: true, originals: true, render: true), for: device.id)
        let id = OfficeProxies.id(root)
        do {
            let stream = RemoteStream.file(share: id, path: "clip.mov", kind: .original)
            let block = RemoteStream.block
            let size = try await stream.size()
            let small = try await stream.bytes(100, 1000)
            let across = try await stream.bytes(Int64(block - 10), 30)
            let tail = try await stream.bytes(Int64(bytes.count - 50), 500)
            let past = try await stream.bytes(Int64(bytes.count + 10), 10)
            var whole = Data(), at: Int64 = 0
            while at < size {
                let piece = try await stream.bytes(at, 700_001)
                if piece.isEmpty { break }
                whole.append(piece)
                at += Int64(piece.count)
            }
            check("review: streamed ranges give the exact bytes",
                  size == Int64(bytes.count) && small == bytes.subdata(in: 100..<1100) && across == bytes.subdata(in: (block - 10)..<(block + 20))
                  && tail == bytes.suffix(50) && past.isEmpty && whole == bytes,
                  "size \(size) small \(small.count) across \(across.count) tail \(tail.count) past \(past.count) whole \(whole.count)")
            // A reader answering in smaller pieces than a block (like the preview's 1.5 MB) still fills it exactly.
            let pieces = RemoteStream(contentType: "public.mpeg-4") { offset, _ in
                try await client.fileData(share: id, path: "clip.mov", kind: .original, offset: offset, length: OfficeLink.previewChunk)
            }
            var all = Data()
            while true {
                let piece = try await pieces.bytes(Int64(all.count), 1 << 20)
                if piece.isEmpty { break }
                all.append(piece)
            }
            let middle = try await pieces.bytes(1_499_990, 20)
            check("review: a reader with small pieces streams exactly", all == bytes && middle == bytes.subdata(in: 1_499_990..<1_500_010),
                  "\(all.count) of \(bytes.count)")
            // A real movie played through the resource loader.
            if await writeMovie(root.appendingPathComponent("movie.mov")) {
                let movie = RemoteStream.file(share: id, path: "movie.mov", kind: .original)
                let asset = movie.asset()
                let duration = try? await asset.load(.duration).seconds
                let tracks = try? await asset.loadTracks(withMediaType: .video)
                let frame = try? await AVAssetImageGenerator(asset: asset).image(at: CMTime(value: 5, timescale: 10)).image
                check("review: a movie plays through the stream", (duration ?? 0) > 0.9 && tracks?.count == 1 && frame?.width == 64,
                      "\(duration ?? -1) \(tracks?.count ?? -1)")
                withExtendedLifetime(movie) {}
            } else {
                check("review: test movie written", false)
            }
            check("review: no proxy yet is an error, not an empty stream",
                  await refused({ _ = try await RemoteStream.file(share: id, path: "clip.mov", kind: .proxy).size() }))
        } catch {
            check("review: streaming", false, error.localizedDescription)
        }

        // A render of this Mac's with a preview, and one of another Mac's.
        let job = OfficeRenderServer.Job(id: UUID(), resolveJob: "1", folder: [], project: "Project", timeline: "<b>Cut</b>", preset: "",
                                         device: device.name, deviceID: device.id, started: .now, state: .done, progress: 1,
                                         preview: previewFile.path, previewSize: Int64(previewBytes.count))
        var other = job
        other.id = UUID()
        other.deviceID = UUID()
        RemoteReview.testJobs = [job, other]
        jobs = [job.id, other.id]
        guard let remoteJob = OfficeRenderClient.Job(job.summary), let otherJob = OfficeRenderClient.Job(other.summary) else {
            return check("review: render summaries", false)
        }
        let typed = "<script>alert(1)</script> & \"quoted\""
        do {
            _ = try await client.addComment(remoteJob, time: 12.5, text: typed)
            var comments = try await client.addComment(remoteJob, time: 3, text: "Earlier")
            check("review: comments come back sorted by time, with this Mac as author",
                  comments.map(\.time) == [3, 12.5] && comments.allSatisfy { $0.author == device.name }, "\(comments.map(\.time))")
            let first = comments[1].id
            _ = try await client.addComment(remoteJob, time: 0, text: "Agreed", reply: first)
            comments = try await client.resolveComment(remoteJob, first, resolved: true)
            let stored = RemoteReview.load(job.id)
            check("review: reply and resolve persist on the host",
                  stored == comments && stored.count == 2 && stored[1].resolved && stored[1].replies.map(\.text) == ["Agreed"] && !stored[0].resolved)
            check("review: a fresh read gives the same", try await client.reviewComments(remoteJob) == stored)
            check("review: another Mac's render is refused", await refused({ _ = try await client.reviewComments(otherJob) }))
            check("review: empty comments are refused", await refused({ _ = try await client.addComment(remoteJob, time: 1, text: "   ") }))
        } catch {
            check("review: comments round trip", false, error.localizedDescription)
        }

        await reviewWebTest(job, typed: typed, preview: previewBytes)

        let edl = RemoteReview.markerEDL([ReviewComment(time: 2, text: "Cut | here\nplease", author: "Mac"),
                                          ReviewComment(time: 61.48, text: "Done", author: "iPhone", resolved: true)], title: "Cut", fps: 25)
        let lines = edl.components(separatedBy: "\n")
        check("review: Resolve marker EDL layout",
              lines.starts(with: ["TITLE: Cut", "FCM: NON-DROP FRAME", "",
                                  "001  001      V     C        01:00:02:00 01:00:02:01 01:00:02:00 01:00:02:01  ",
                                  " |C:ResolveColorRed |M:Mac: Cut / here please |D:1", "",
                                  "002  001      V     C        01:01:01:12 01:01:01:13 01:01:01:12 01:01:01:13  ",
                                  " |C:ResolveColorGreen |M:iPhone: Done |D:1"]), edl)
    }

    /// The Library server's /review pages, over HTTP on this Mac.
    private static func reviewWebTest(_ job: OfficeRenderServer.Job, typed: String, preview: Data) async {
        let library = LibraryServer.shared, defaults = UserDefaults.standard
        let wasSharing = defaults.bool(forKey: LibraryServer.enabledKey)
        defaults.set(true, forKey: "PluckScreenshotAnyPort")
        defaults.set(true, forKey: LibraryServer.enabledKey)
        library.start()
        for _ in 0..<100 where !library.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        defer {
            defaults.set(wasSharing, forKey: LibraryServer.enabledKey)
            library.stop()
            defaults.removeObject(forKey: "PluckScreenshotAnyPort")
        }
        guard let port = library.port else { return check("review web: Library server started", false, library.problem ?? "") }
        final class NoRedirect: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest) async -> URLRequest? { nil }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        func call(_ path: String, post: String? = nil, cookie: String? = nil, range: String? = nil) async -> (Int, Data, HTTPURLResponse?) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
            if let post {
                request.httpMethod = "POST"
                request.httpBody = Data(post.utf8)
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
            if let cookie { request.setValue("pluck_session=\(cookie)", forHTTPHeaderField: "Cookie") }
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return (0, Data(), nil) }
            return (http.statusCode, data, http)
        }
        let page = "/review/\(job.id.uuidString)"
        let noSession = await call(page), noVideo = await call(page + "/video"), noList = await call("/review")
        let noPost = await call(page + "/add", post: "text=sneaky&time=1")
        check("review web: refused without a session", noSession.0 == 401 && noVideo.0 == 401 && noList.0 == 401 && noPost.0 == 401,
              "\(noSession.0) \(noVideo.0) \(noList.0) \(noPost.0)")
        check("review web: nothing added without a session", !RemoteReview.load(job.id).contains { $0.text == "sneaky" })

        let login = await call("/login", post: "code=\(library.code)")
        let cookie = (login.2?.value(forHTTPHeaderField: "Set-Cookie") ?? "").split(separator: ";").first
            .flatMap { $0.hasPrefix("pluck_session=") ? String($0.dropFirst("pluck_session=".count)) : nil }
        guard login.0 == 303, let cookie else { return check("review web: logged in with the code", false, "\(login.0)") }
        let shown = await call(page, cookie: cookie)
        let html = String(decoding: shown.1, as: UTF8.self)
        check("review web: the page escapes what people typed",
              shown.0 == 200 && html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quoted&quot;") && !html.contains("<script>alert")
              && html.contains("&lt;b&gt;Cut&lt;/b&gt;") && !html.contains("<b>Cut</b>"), String(html.prefix(300)))
        let list = await call("/review", cookie: cookie)
        check("review web: the list shows the render", list.0 == 200 && String(decoding: list.1, as: UTF8.self).contains(page))
        let video = await call(page + "/video", cookie: cookie, range: "bytes=10-19")
        check("review web: the preview plays with ranges", video.0 == 206 && video.1 == preview.subdata(in: 10..<20), "\(video.0) \(video.1.count)")
        let added = await call(page + "/add", post: "time=5.5&text=From+the+phone+%3Ci%3E", cookie: cookie)
        let stored = RemoteReview.load(job.id)
        check("review web: a phone comments with its device label",
              added.0 == 303 && stored.contains { $0.text == "From the phone <i>" && $0.author == "iPhone" && $0.time == 5.5 }, "\(added.0)")
        if let phone = stored.first(where: { $0.author == "iPhone" }) {
            _ = await call(page + "/resolve", post: "comment=\(phone.id.uuidString)&resolved=1", cookie: cookie)
            check("review web: a phone resolves", RemoteReview.load(job.id).first { $0.id == phone.id }?.resolved == true)
        }
        check("review web: an unknown render is not found", await call("/review/\(UUID().uuidString)", cookie: cookie).0 == 404)
    }

    /// One second of a 64×48 H.264 movie.
    private static func writeMovie(_ url: URL) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<10 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { return false }
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        await writer.finishWriting()
        return writer.status == .completed
    }
}
