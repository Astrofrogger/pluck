import Foundation

extension PhotoSelfTest {
    /// Parts of originals (part of remotepull): ranges merged with handles and clamped, the plan from Resolve's uses
    /// through the manifest (RAW, retimed and nested whole), keyframe snapping, pieces cut from a generated long-GOP and
    /// ProRes file (frames, timecode + offset, reel), a pull of pieces over the loopback pairing, and whole files when
    /// the office Mac doesn't know `originalPiece`.
    static func remotePiecesTest(share: OfficeRenderClient.RemoteShare, root: URL, local: URL, device: UUID) async {
        let fm = FileManager.default
        // Merge, handles, clamping.
        check("pieces: uses merge into one span with handles", RemotePieces.merge([100...150, 120...300, 500...510], handles: 50, frames: 1000) == 50...560)
        check("pieces: handles clamp to the clip", RemotePieces.merge([10...20, 980...995], handles: 50, frames: 1000) == 0...999)
        check("pieces: no uses, no span", RemotePieces.merge([], handles: 50, frames: 1000) == nil)

        // The plan through the manifest.
        let proxyRoot = URL(fileURLWithPath: "/tmp/pp", isDirectory: true)
        let entries = [RemoteManifestEntry(share: "s", path: "Day 1/A.MP4", proxy: "Day 1/A.mov", reel: "A", duration: 40, fps: 25, size: 1),
                       RemoteManifestEntry(share: "s", path: "Day 1/B.braw", proxy: "Day 1/B.mov", reel: "B", duration: 40, fps: 25, size: 1),
                       RemoteManifestEntry(share: "s", path: "Day 1/C.MOV", proxy: "Day 1/C.mov", reel: "C", duration: 40, fps: 25, size: 1),
                       RemoteManifestEntry(share: "s", path: "Day 1/D.MOV", proxy: "Day 1/D.mov", reel: "D", duration: 40, fps: 25, size: 1)]
        let manifest = RemoteManifest(host: "h", hostName: "H", share: "s", shareName: "S", entries: entries)
        let answer: [String: Any] = ["items": [["file": "/tmp/pp/Day 1/A.mov", "start": 200, "end": 300],
                                               ["file": "/tmp/pp/Day 1/./A.mov", "start": 400, "end": 420],
                                               ["file": "/tmp/pp/Day 1/B.mov", "start": 0, "end": 10],
                                               ["file": "/tmp/pp/Day 1/C.mov", "start": 0, "end": 10, "retimed": true],
                                               ["file": "/elsewhere/X.mov", "start": 0, "end": 10]],
                                     "whole": ["/tmp/pp/Day 1/D.mov"]]
        let found = RemotePieces.uses(answer)
        let plan = RemotePieces.plan(found.uses, whole: found.whole, roots: [(manifest, proxyRoot)], handles: 2)
        check("pieces: plan maps proxies to originals, other files left out", plan.map(\.path) == ["Day 1/A.MP4", "Day 1/B.braw", "Day 1/C.MOV", "Day 1/D.MOV"], "\(plan)")
        check("pieces: plan merges a clip's uses with 2 s handles", plan.first?.range == 150...470, "\(String(describing: plan.first))")
        check("pieces: RAW, retimed and nested come whole with why", plan.dropFirst().allSatisfy { $0.range == nil && $0.whole != nil }
              && plan[1].whole == String(localized: "RAW can’t be cut"), "\(plan)")
        check("pieces: the estimate is the used share", RemotePieces.estimate(plan[0], size: 1000 << 20) < 400 << 20)

        // Keyframe snapping (pure).
        let span = RemotePieces.span(first: 160, last: 190, fps: 25, intra: false, keys: [0, 2, 4, 6, 8, 10])
        check("pieces: long-GOP starts at the keyframe before and ends at the next after", span.first == 150 && span.end == 200, "\(span)")
        check("pieces: long-GOP past the last keyframe runs to the end", RemotePieces.span(first: 260, last: 270, fps: 25, intra: false, keys: [0, 10]).end == nil)
        check("pieces: intra is frame exact", RemotePieces.span(first: 160, last: 190, fps: 25, intra: true, keys: []) == (160, 191))

        // Cut from real files.
        guard let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg"), let ffprobe = OfficeRenderServer.shared.manager?.tool("ffprobe") else {
            return check("pieces: ffmpeg for the test", false)
        }
        try? fm.createDirectory(at: root.appendingPathComponent("Cuts"), withIntermediateDirectories: true)
        func make(_ name: String, _ codec: [String]) -> URL {
            let file = root.appendingPathComponent("Cuts/" + name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000",
                                 "-t", "20"] + codec + ["-timecode", "01:00:00:00", "-metadata:s:v:0", "reel_name=R" + name.prefix(1), file.path]
            try? process.run()
            process.waitUntilExit()
            return file
        }
        let long = make("L.mp4", ["-c:v", "libx264", "-g", "50", "-bf", "2", "-c:a", "aac"])
        let prores = make("P.mov", ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le"])
        func frames(_ file: URL) -> Int {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-select_streams", "v:0", "-count_frames", "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", file.path]
            process.standardOutput = pipe
            try? process.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            // (ffprobe 8 prints the stream's line twice, the first time for its stream group.)
            return text.split(whereSeparator: \.isNewline).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? -1
        }
        do {
            let piece = try RemotePieces.make(long, share: share.id, relative: "Cuts/L.mp4", first: 160, last: 190, ffmpeg: ffmpeg, ffprobe: ffprobe)
            let file = RemotePieces.file(share: share.id, relative: "Cuts/L.mp4", first: piece.first, last: piece.last)
            let probed = RemotePieces.probe(file, ffprobe: ffprobe)
            check("pieces: long-GOP piece from the keyframe before, never shorter", piece.first == 150 && piece.last >= 190 && frames(file) >= 41, "\(piece) \(frames(file))")
            check("pieces: piece timecode is the original's plus the offset", piece.timecode == "01:00:06:00" && probed.timecode == "01:00:06:00",
                  "\(String(describing: piece.timecode)) \(String(describing: probed.timecode)) \(String(describing: probed.reel))")
            check("pieces: piece keeps the original's name", file.lastPathComponent == "L.mp4")
            let again = try RemotePieces.make(long, share: share.id, relative: "Cuts/L.mp4", first: 160, last: 190, ffmpeg: ffmpeg, ffprobe: ffprobe)
            check("pieces: a piece cut before is kept", again == piece)
            let exact = try RemotePieces.make(prores, share: share.id, relative: "Cuts/P.mov", first: 160, last: 190, ffmpeg: ffmpeg, ffprobe: ffprobe)
            let exactFile = RemotePieces.file(share: share.id, relative: "Cuts/P.mov", first: 160, last: 190)
            check("pieces: ProRes piece is frame exact", exact.first == 160 && exact.last == 190 && frames(exactFile) == 31, "\(exact) \(frames(exactFile))")
            let exactProbe = OfficeProxies.probe(exactFile, ffprobe: ffprobe)
            check("pieces: ProRes piece timecode and reel", exact.timecode == "01:00:06:10" && exactProbe.1 == "01:00:06:10" && exactProbe.3 == "RP",
                  "\(String(describing: exact.timecode)) \(String(describing: exactProbe.3))")
        } catch {
            check("pieces: cut", false, "\(error)")
        }
        let raw = root.appendingPathComponent("Cuts/R.braw")
        fm.createFile(atPath: raw.path, contents: Data(count: 100))
        check("pieces: RAW is never cut", (try? RemotePieces.make(raw, share: share.id, relative: "Cuts/R.braw", first: 0, last: 10, ffmpeg: ffmpeg, ffprobe: ffprobe)) == nil)

        // A pull of pieces over the pairing (originals allowed), then from an office that doesn't know the action.
        let server = OfficeRenderServer.shared, pulls = RemotePullManager.shared
        server.setRights(.init(browse: true, proxies: true, originals: true, render: true), for: device)
        defer { server.setRights(.init(), for: device) }
        let size = Int64((try? fm.attributesOfItem(atPath: prores.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let item = RemotePieces.Item(share: share.id, path: "Cuts/P.mov", range: 100...149, frames: 500)
        let target = local.appendingPathComponent("Originals/Cuts/P.mov")
        pulls.pullPieces(share: share, items: [item], sizes: ["Cuts/P.mov": size], into: local)
        if let job = pulls.jobs.first(where: { $0.paths == ["Cuts/P.mov"] }) {
            _ = await pulls.pass(job)
            let pieceSize = RemotePullManager.size(of: target) ?? 0
            check("pieces: a pull fetches the piece, checked", pulls.progress[job.id]?.finished == true && pieceSize > 0 && pieceSize < size / 4
                  && frames(target) == 50, "\(String(describing: pulls.progress[job.id])) \(pieceSize)")
            let mapped = RemoteManifest.load(in: local)?.entries.first { $0.pieceOf == "Cuts/P.mov" }
            check("pieces: the share's manifest knows the piece's original and range", mapped?.proxy == "Originals/Cuts/P.mov" && mapped?.range == [100, 149],
                  "\(String(describing: mapped))")
            let render = RemoteResolveMap.proxies(for: [target.path], roots: [(RemoteManifest.load(in: local)!, local)])
            check("pieces: a render maps the piece back to its original", render.first?.path == "Cuts/P.mov" && render.first?.piece == true, "\(render)")
            check("pieces: pieces are never linked as proxies", RemoteResolveMap.links(RemoteManifest.load(in: local)!, proxyRoot: local, originalRoot: "/x").allSatisfy {
                ($0["proxy"] as? String)?.contains("Originals") != true })
            pulls.remove(job)
        } else {
            check("pieces: the pull is kept", false)
        }
        try? fm.removeItem(at: target)
        let saved = RemotePieces.action
        RemotePieces.action = "originalPieceNobodyKnows"
        defer { RemotePieces.action = saved }
        pulls.pullPieces(share: share, items: [item], sizes: ["Cuts/P.mov": size], into: local)
        if let job = pulls.jobs.first(where: { $0.paths == ["Cuts/P.mov"] }) {
            _ = await pulls.pass(job)
            check("pieces: an office that doesn't know pieces sends the whole file, said quietly",
                  RemotePullManager.size(of: target) == size && pulls.progress[job.id]?.note != nil, "\(String(describing: pulls.progress[job.id]))")
            pulls.remove(job)
        }
        try? fm.removeItem(at: RemotePieces.cache)
    }
}
