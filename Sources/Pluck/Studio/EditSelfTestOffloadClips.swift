import AVFoundation
import Foundation
import PDFKit

/// Offload clip details and speeds (Tasks 2 and 3): read from a real MP4, safe on damage, never
/// in the copy's way; and each drive's and the card's speed kept in the job.
extension EditSelfTest {
    static func offloadClips() async {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-offload-clips-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let before = Set(OffloadCenter.shared.jobs.map(\.id))
        await clipDetailsRead(base)
        await clipDetailsDamaged(base)
        await detailsNeverBlock(base)
        await speedsPerDrive(base)
        holdingBack()
        wrapChecks()
        for job in OffloadCenter.shared.jobs where !before.contains(job.id) { OffloadCenter.shared.remove(job.id) }
        try? FileManager.default.removeItem(at: base)
    }

    /// A 2 second, 25 fps, 640 x 360 H.264 movie.
    private static func makeMovie(_ url: URL) async -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<50 {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(frame * 5 % 256), CVPixelBufferGetDataSize(buffer)) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 50, timescale: 25))
        await writer.finishWriting()
        return writer.status == .completed
    }

    private static func clipDetailsRead(_ base: URL) async {
        let movie = base.appendingPathComponent("details.mp4")
        guard await makeMovie(movie) else { return check("clip details read", false, "couldn't make the movie") }
        let details = await OffloadClips.read(movie)
        let picture = await OffloadClips.thumbnail(movie, size: 160)
        check("clip details read", abs((details.duration ?? 0) - 2) < 0.1 && details.fps == 25 && details.width == 640 && details.height == 360
              && details.path == movie.path && details.codec == "H.264" && picture != nil,
              "2 s, 25 fps, 640x360, H.264, a picture; got \(details.duration ?? -1), \(details.fps ?? -1), \(details.width ?? -1)x\(details.height ?? -1), \(details.codec ?? "nil"), \(picture != nil)")
    }

    private static func clipDetailsDamaged(_ base: URL) async {
        let movie = base.appendingPathComponent("whole.mp4"), cut = base.appendingPathComponent("cut.mp4")
        guard await makeMovie(movie), let data = try? Data(contentsOf: movie) else { return check("clip details survive damage", false, "couldn't make the movie") }
        try? data.prefix(data.count * 2 / 5).write(to: cut)
        let broken = await OffloadClips.read(cut)
        let missing = await OffloadClips.read(base.appendingPathComponent("not there.mov"))
        let raw = await OffloadClips.read(base.appendingPathComponent("not there.r3d"))
        check("clip details survive damage", broken.path == cut.path && broken.duration == nil && broken.width == nil && broken.fps == nil
              && missing.path.hasSuffix("not there.mov") && raw.path.hasSuffix("not there.r3d") && raw.width == nil,
              "path kept, fields nil; got \(broken.duration ?? -1), \(broken.width ?? -1), \(missing.path), \(raw.path)")
    }

    /// A card of `count` clips of 200 KB, in a folder of its own.
    private static func bigCard(_ base: URL, _ name: String, count: Int) -> URL {
        let card = base.appendingPathComponent(name, isDirectory: true)
        let folder = card.appendingPathComponent("DCIM/100MEDIA", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 1...count {
            let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ n &* 7 &+ name.count) })
            try? bytes.write(to: folder.appendingPathComponent(String(format: "C%04d.MP4", n)))
        }
        return card
    }

    /// Offloads a card to a drive of its own, and waits for it: the job, and how long it took.
    private static func timedOffload(_ base: URL, _ name: String, count: Int = 50) async -> (job: OffloadJob, seconds: Double)? {
        let drive = base.appendingPathComponent("Drive \(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let card = bigCard(base, "Card \(name)", count: count)
        guard await OffloadCenter.shared.add(source: card, roots: [drive], name: name) == nil, let id = OffloadCenter.shared.jobs.first?.id else { return nil }
        for _ in 0..<600 {
            if let job = OffloadCenter.shared.jobs.first(where: { $0.id == id }), OffloadCenter.shared.state(job) == .done, let end = job.finished {
                return (job, end.timeIntervalSince(job.started))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// 50 files with the details off, then with them on (and the next card copying while the
    /// details of the one before are worked out): the same speed, within 10 %.
    private static func detailsNeverBlock(_ base: URL) async {
        OffloadCenter.detailsOn = false
        let plain = await timedOffload(base, "Plain")
        OffloadCenter.detailsOn = true
        let first = await timedOffload(base, "WithOne")
        let second = await timedOffload(base, "WithTwo")
        guard let plain, let first, let second else { return check("details never block the copy", false, "an offload didn't finish") }
        var worked = false
        for _ in 0..<300 {
            if OffloadCenter.shared.details(for: first.job.id)?.count == 50 { worked = true; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let none = OffloadCenter.shared.details(for: plain.job.id) == nil
        // (A quarter of a second of slack: 50 small files take well under a second.)
        let slowest = max(first.seconds, second.seconds)
        check("details never block the copy", slowest <= plain.seconds * 1.1 + 0.25 && worked && none,
              "with details \(slowest) s vs without \(plain.seconds) s (+10 %); details made \(worked), none when off \(none)")
    }

    private static func speedsPerDrive(_ base: URL) async {
        let card = bigCard(base, "Card Speeds", count: 6)
        let one = base.appendingPathComponent("Drive Speeds 1", isDirectory: true), two = base.appendingPathComponent("Drive Speeds 2", isDirectory: true)
        for drive in [one, two] { try? FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true) }
        let problem = await OffloadCenter.shared.add(source: card, roots: [one, two], name: "Speeds")
        guard problem == nil, let id = OffloadCenter.shared.jobs.first?.id else { return check("speeds per drive", false, "didn't start: \(problem ?? "")") }
        var job: OffloadJob?
        for _ in 0..<300 {
            job = OffloadCenter.shared.jobs.first { $0.id == id }
            if let job, OffloadCenter.shared.state(job) == .done { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let names = job?.speedNames
        let speeds = job?.speeds ?? [:]
        let wanted = names.map { [$0.card] + $0.drives } ?? []
        check("speeds per drive", wanted.count == 3 && Set(speeds.keys) == Set(wanted) && speeds.values.allSatisfy { $0 > 0 },
              "an average for the card and each drive, all above 0; got \(speeds)")
    }

    /// A drive under 60 % of the fastest for 10 s is named; one that catches up is not.
    private static func holdingBack() {
        var history = SpeedHistory(drives: 2)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for second in 0..<9 { history.add([100, 40, 150], at: start.addingTimeInterval(Double(second))) }
        let early = history.holdingBack
        history.add([100, 40, 150], at: start.addingTimeInterval(10))
        let named = history.holdingBack
        history.add([100, 90, 150], at: start.addingTimeInterval(11))
        check("drive holding back", early == nil && named == 1 && history.holdingBack == nil,
              "nothing at 9 s, drive 2 at 10 s, nothing once it catches up; got \(String(describing: early)), \(String(describing: named)), \(String(describing: history.holdingBack))")
    }

    /// Three made-up cards over two people and two cameras.
    private static func wrapJobs() -> (project: OffloadProject, jobs: [OffloadJob], one: OffloadProject.Operator, two: OffloadProject.Operator) {
        let one = OffloadProject.Operator(name: "Operator A", letter: "A"), two = OffloadProject.Operator(name: "Operator B", letter: "B")
        var project = OffloadProject(name: "Wrap Test")
        project.operators = [one, two]
        func job(_ card: String, _ person: OffloadProject.Operator, _ camera: String, _ sizes: [Int64], problem: Bool = false) -> OffloadJob {
            let files = sizes.enumerated().map { index, size in
                OffloadFile(path: "\(card)/C\(index).mov", size: size, modified: .now, hash: "00", done: [true],
                            problem: problem && index == 0 ? "Not readable" : nil)
            }
            var made = OffloadJob(name: card, source: "/Volumes/\(card)", sourceVolume: card, roots: ["/tmp"], rootVolumes: ["Drive"], files: files)
            made.finished = .now
            made.project = project.id
            made.operatorID = person.id
            made.card = card
            made.camera = camera
            made.title = card + " · " + person.name
            return made
        }
        return (project, [job("A001", one, "Camera X", [100, 50]), job("A002", one, "Camera Y", [200]),
                          job("B001", two, "Camera X", [400, 10], problem: true)], one, two)
    }

    private static func wrapChecks() {
        let made = wrapJobs()
        let ids = made.jobs.map(\.id)
        let clips: (UUID) -> [ClipDetails]? = { id in
            var clip = ClipDetails(path: "x.mov")
            clip.duration = id == ids[0] ? 60 : 30
            return id == ids[2] ? nil : [clip]
        }
        let stats = OffloadWrap.stats(project: made.project, jobs: made.jobs, days: nil, details: clips)
        let a = stats.perOperator[made.one.id], b = stats.perOperator[made.two.id]
        let x = stats.perCamera["Camera X"], y = stats.perCamera["Camera Y"]
        // A day with no cards in it has none of the totals.
        let past = Date(timeIntervalSince1970: 1_000_000)
        let none = OffloadWrap.stats(project: made.project, jobs: made.jobs, days: OffloadWrap.range(of: past), details: clips)
        check("wrap stats add up", stats.cards == 3 && stats.bytes == 760 && stats.duration == 90 && stats.problems == 1
              && a == .init(cards: 2, bytes: 350, duration: 90) && b == .init(cards: 1, bytes: 410, duration: 0)
              && x == .init(cards: 2, bytes: 560, duration: 60) && y == .init(cards: 1, bytes: 200, duration: 30)
              && stats.busiest == made.one.id && none.cards == 0,
              "got \(stats.cards) cards, \(stats.bytes) B, \(stats.duration) s, \(stats.problems) problems; people \(String(describing: a)) \(String(describing: b)); cameras \(String(describing: x)) \(String(describing: y))")
        let data = OffloadWrap.pdf(project: made.project, jobs: made.jobs, days: nil, details: clips)
        let document = PDFDocument(data: data)
        let words = document?.string ?? ""
        check("wrap pdf", (document?.pageCount ?? 0) >= 1 && ["A001", "A002", "B001", "Not readable"].allSatisfy(words.contains),
              "\(document?.pageCount ?? 0) pages; text: \(words.prefix(200))")
    }
}
