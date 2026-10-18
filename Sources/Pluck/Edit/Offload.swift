import AppKit
import Darwin

/// Offload, as OffShoot and Silverstack do it: a card (or any folder) copied to one or more
/// drives at once, every copy read back and checked against the card with xxHash64. The job is
/// kept on disk, so a drive that disconnects (or Pluck quitting) only pauses it: it carries on
/// where it was, down to the byte, and a report (MHL) is written next to each copy at the end.
struct OffloadFile: Codable, Hashable {
    /// Where it is in the source folder.
    var path: String
    var size: Int64
    var modified: Date
    /// The source's xxHash64, once it's been read.
    var hash: String?
    var hashed: Date?
    /// Checked on each destination.
    var done: [Bool]
    var problem: String?
}

struct OffloadJob: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var source: String
    var sourceVolume: String
    /// The folders chosen; each copy goes into a folder named `name` in them.
    var roots: [String]
    var rootVolumes: [String]
    var files: [OffloadFile]
    var started = Date.now
    var finished: Date?
    /// The card to the first drive, then that drive to the others (the card is free sooner).
    var cascade: Bool?
    /// The card is ejected once it's no longer needed.
    var ejectSource: Bool?
    /// When the card was no longer needed.
    var cardDone: Date?
    /// Seconds spent copying and checking (not paused or waiting for a drive).
    var busy: Double?
    /// It was copying, or waiting for a drive, when Pluck last stopped: it carries on when Pluck
    /// opens again (after a crash, a restart or a power cut), unless it was paused.
    var running: Bool?

    var cascades: Bool { cascade == true && roots.count > 1 }
    var targets: [String] { roots.map { ($0 as NSString).appendingPathComponent(name) } }
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    var problems: [OffloadFile] { files.filter { $0.problem != nil } }
    var isComplete: Bool { files.allSatisfy { $0.problem != nil || !$0.done.contains(false) } }
    /// The work in bytes: each file read once from the source and once from every copy (and, when
    /// it cascades, once more from the first copy).
    var work: Int64 { totalBytes * Int64(perFile) }
    private var perFile: Int { 1 + roots.count + (cascades ? 1 : 0) }
    var workDone: Int64 {
        files.reduce(0) { sum, file in
            if file.problem != nil || !file.done.contains(false) { return sum + file.size * Int64(perFile) }
            // On the first drive, not yet on the others.
            if cascades, file.done.first == true { return sum + file.size * 2 }
            return sum
        }
    }
}

// MARK: - The copying

/// One job's copying, on its own thread: stoppable, and telling the page how far it is.
final class OffloadRunner: @unchecked Sendable {
    enum Phase: Sendable { case copying, checking }
    enum Event: Sendable {
        case progress(bytes: Int64, file: String, phase: Phase)
        case file(Int, OffloadFile)
        /// A drive (by name) isn't there: paused until it's back.
        case waiting(String)
        /// Everything is off the card: it can go back in the camera.
        case cardDone
        case stopped(String?)
        case finished
    }

    private enum Halt: Error { case stop, waiting(String), fatal(String) }

    private let lock = NSLock()
    private var stopping = false
    /// Whether this pass reads from the card (not from the first copy), and the drives it uses.
    private var fromCard = true
    private var drives: [Int] = []
    /// The device each place was on when the pass began: a drive pulled out can leave its folder
    /// in /Volumes for a moment (then on the Mac's own disk), so being there isn't enough.
    private var devices: [String: dev_t] = [:]
    private var job: OffloadJob
    private let send: @Sendable (Event) -> Void
    private static let chunk = 8 << 20

    init(job: OffloadJob, send: @escaping @Sendable (Event) -> Void) {
        self.job = job
        self.send = send
    }

    func stop() { lock.withLock { stopping = true } }
    private var isStopping: Bool { lock.withLock { stopping } }

    func start() {
        let thread = Thread { [self] in run() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func run() {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        // The Mac stays awake while it copies (an offload often runs unattended, overnight).
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Offloading \(job.name)")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            if job.cascades {
                if job.cardDone == nil {
                    try pass(from: job.source, to: [0], buffer: buffer)
                    job.cardDone = .now
                    send(.cardDone)
                }
                try pass(from: job.targets[0], to: Array(1..<job.roots.count), buffer: buffer)
            } else {
                try pass(from: job.source, to: Array(job.roots.indices), buffer: buffer)
            }
            for target in job.targets.indices { writeReport(target) }
            send(.finished)
        } catch Halt.waiting(let drive) {
            send(.waiting(drive))
        } catch Halt.fatal(let problem) {
            send(.stopped(problem))
        } catch {
            send(.stopped(nil))
        }
    }

    /// Every file still to do, from one place to some of the drives.
    private func pass(from root: String, to destinations: [Int], buffer: UnsafeMutableRawPointer) throws {
        fromCard = root == job.source
        drives = fromCard ? destinations : [0] + destinations
        devices = [:]
        try checkDrives()
        for path in [job.source] + drives.map({ job.roots[$0] }) {
            if let device = Self.device(path) { devices[path] = device }
        }
        for index in job.files.indices where job.files[index].problem == nil && destinations.contains(where: { !job.files[index].done[$0] }) {
            if isStopping { throw Halt.stop }
            var file = job.files[index]
            do {
                try copy(&file, from: root, to: destinations, buffer: buffer, retry: true)
            } catch let halt as Halt {
                throw halt
            } catch {
                // Something with this file alone: noted, and on with the rest.
                try checkDrivesAfterFailure()
                file.problem = (error as NSError).localizedDescription
            }
            job.files[index] = file
            send(.file(index, file))
        }
    }

    /// Every drive this pass needs is there (and still the same drive), or the job waits for it.
    private func checkDrives() throws {
        func gone(_ path: String) -> Bool {
            guard let now = Self.device(path) else { return true }
            return devices[path].map { $0 != now } ?? false
        }
        if fromCard, gone(job.source) { throw Halt.waiting(job.sourceVolume) }
        for drive in drives where gone(job.roots[drive]) {
            throw Halt.waiting(job.rootVolumes[drive])
        }
    }

    /// After a read or write failed: whether a drive went away. A drive being pulled out takes a
    /// moment to show as gone, so it's looked at again for a couple of seconds before the
    /// failure is put down to the file itself.
    private func checkDrivesAfterFailure() throws {
        for _ in 0..<8 {
            try checkDrives()
            Thread.sleep(forTimeInterval: 0.25)
        }
        try checkDrives()
    }

    /// The device a path is on (nil if it isn't there).
    private static func device(_ path: String) -> dev_t? {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_dev : nil
    }

    private struct Writer {
        let destination: Int
        let target: String
        let partial: String
        let fd: Int32
        let from: Int64
    }

    /// Reads the file once, writing it to every copy still to do (from where a copy stopped, if
    /// it did), then reads each copy back and checks it.
    private func copy(_ file: inout OffloadFile, from root: String, to destinations: [Int], buffer: UnsafeMutableRawPointer, retry: Bool) throws {
        let source = (root as NSString).appendingPathComponent(file.path)
        let pending = destinations.filter { !file.done[$0] }
        var writers: [Writer] = []
        var existing: [(destination: Int, target: String)] = []
        defer { for writer in writers { close(writer.fd) } }
        for destination in pending {
            let target = (job.targets[destination] as NSString).appendingPathComponent(file.path)
            let folder = (target as NSString).deletingLastPathComponent
            do {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            } catch {
                try checkDrivesAfterFailure()
                throw error
            }
            if FileManager.default.fileExists(atPath: target) {
                // Already there (an earlier offload to the same folder): checked, not written.
                existing.append((destination, target))
                continue
            }
            let partial = (folder as NSString).appendingPathComponent("." + (target as NSString).lastPathComponent + ".pluckpart")
            let fd = open(partial, O_WRONLY | O_CREAT, 0o644)
            guard fd >= 0 else { let code = errno; try checkDrivesAfterFailure(); throw Self.error(code, partial) }
            _ = fcntl(fd, F_NOCACHE, 1)
            // Carry on from what was written before, less the last bit (it may not have reached the disk).
            var info = stat()
            let had = fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
            let from = max(min(had, file.size) / Int64(Self.chunk) * Int64(Self.chunk) - Int64(Self.chunk), 0)
            _ = ftruncate(fd, off_t(from))
            writers.append(Writer(destination: destination, target: target, partial: partial, fd: fd, from: from))
        }

        // One read of the source, hashed and written to every copy.
        let input = open(source, O_RDONLY)
        guard input >= 0 else {
            let code = errno
            try checkDrivesAfterFailure()
            throw Self.error(code, source)
        }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        var hasher = XXH64()
        var position: Int64 = 0
        var lastReport = Date.distantPast
        // The next piece comes off the card while this one is written.
        let reader = ReadAhead(fd: input, first: buffer, size: Self.chunk)
        while true {
            if isStopping { throw Halt.stop }
            let (buffer, count, code) = reader.next()
            if count < 0 { try checkDrivesAfterFailure(); throw Self.error(code, source) }
            if count == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: count))
            let end = position + Int64(count)
            // Every drive written at once (each at its own speed, not one after the other); copies
            // on the same drive one after another.
            let groups = byDrive(writers.filter { end > $0.from }, drive: \.destination)
            var failures = [(Writer, Int32)?](repeating: nil, count: groups.count)
            let start = position
            failures.withUnsafeMutableBufferPointer { results in
                DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                    for writer in groups[g] {
                        var written = Int(max(writer.from - start, 0))
                        while written < count {
                            let n = pwrite(writer.fd, buffer + written, count - written, off_t(start) + off_t(written))
                            if n < 0 { results[g] = (writer, errno); return }
                            written += n
                        }
                    }
                }
            }
            if let (writer, code) = failures.compactMap({ $0 }).first {
                try checkDrivesAfterFailure()
                if code == ENOSPC { throw Halt.fatal(String(localized: "There’s no room left on \(job.rootVolumes[writer.destination]).")) }
                if code == EFBIG {
                    throw NSError(domain: "Pluck", code: 44, userInfo: [NSLocalizedDescriptionKey:
                        String(localized: "It’s too big for \(job.rootVolumes[writer.destination]) (a FAT32 drive holds files up to 4 GB).")])
                }
                throw Self.error(code, writer.target)
            }
            position = end
            if Date.now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = .now
                send(.progress(bytes: position, file: file.path, phase: .copying))
            }
        }
        let hash = String(format: "%016llx", hasher.digest())
        if let earlier = file.hash, earlier != hash {
            throw NSError(domain: "Pluck", code: 41, userInfo: [NSLocalizedDescriptionKey: fromCard
                ? String(localized: "It changed on the source since the first copy.")
                : String(localized: "The first copy no longer matches the card.")])
        }
        file.hash = hash
        file.hashed = .now
        file.size = position

        // Each copy onto the disk, under its own name, with the source's date.
        for writer in writers {
            // Onto the disk itself, not just its cache (drives that can't do that: as far as they can).
            if fcntl(writer.fd, F_FULLFSYNC) != 0 { _ = fsync(writer.fd) }
            do {
                try FileManager.default.moveItem(atPath: writer.partial, toPath: writer.target)
                try? FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: writer.target)
            } catch {
                try checkDrivesAfterFailure()
                throw error
            }
        }

        // Read back and checked, every drive at once.
        let checks = writers.map { (destination: $0.destination, target: $0.target, ours: true) }
            + existing.map { (destination: $0.destination, target: $0.target, ours: false) }
        let groups = byDrive(Array(checks.indices), drive: { checks[$0].destination })
        var hashes = [Result<String, Error>?](repeating: nil, count: checks.count)
        let checked = Counter()
        let total = position, name = file.path
        hashes.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: groups.count) { g in
                for index in groups[g] {
                    results[index] = Result {
                        try hashFile(checks[index].target) { bytes in
                            // This file's work so far: read once, and the copies checked so far.
                            if let sum = checked.add(bytes) { send(.progress(bytes: total + sum, file: name, phase: .checking)) }
                        }
                    }
                }
            }
        }
        // A drive gone, or Stop, before anything else.
        for result in hashes { if case .failure(let halt as Halt)? = result { throw halt } }
        var mismatched = false
        for (index, (destination, target, ours)) in checks.enumerated() {
            let copied = try hashes[index]!.get()
            if copied == hash {
                file.done[destination] = true
            } else if ours {
                try? FileManager.default.removeItem(atPath: target)
                mismatched = true
            } else {
                throw NSError(domain: "Pluck", code: 42, userInfo: [NSLocalizedDescriptionKey:
                    String(localized: "A different file with this name is already on \(job.rootVolumes[destination]).")])
            }
        }
        if mismatched {
            // Once more from the start; twice wrong is a problem with the drive.
            guard retry else {
                throw NSError(domain: "Pluck", code: 43, userInfo: [NSLocalizedDescriptionKey: String(localized: "The copy didn’t match the source, twice.")])
            }
            try copy(&file, from: root, to: destinations, buffer: buffer, retry: false)
        }
    }

    /// Groups of things on the same drive (by the device its folder is on), each group to be done
    /// one after another, the groups side by side.
    private func byDrive<T>(_ items: [T], drive: (T) -> Int) -> [[T]] {
        var groups: [dev_t: [T]] = [:], order: [dev_t] = []
        for item in items {
            let device = devices[job.roots[drive(item)]] ?? dev_t(drive(item))
            if groups[device] == nil { order.append(device) }
            groups[device, default: []].append(item)
        }
        return order.map { groups[$0]! }
    }

    /// Reads a file a piece ahead on another thread, into two buffers taken in turn.
    private final class ReadAhead: @unchecked Sendable {
        private let fd: Int32
        private let size: Int
        private let buffers: [UnsafeMutableRawPointer]
        private let group = DispatchGroup()
        private var result = (count: 0, error: Int32(0))
        private var turn = 0

        init(fd: Int32, first: UnsafeMutableRawPointer, size: Int) {
            self.fd = fd
            self.size = size
            buffers = [first, UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)]
            read(into: 0)
        }

        deinit {
            // A read still under way must finish before its buffer goes.
            group.wait()
            buffers[1].deallocate()
        }

        private func read(into index: Int) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let count = Darwin.read(fd, buffers[index], size)
                result = (count, count < 0 ? errno : 0)
                group.leave()
            }
        }

        /// The next piece: where it is, how long (0 at the end, below 0 on an error) and the error.
        func next() -> (UnsafeMutableRawPointer, Int, Int32) {
            group.wait()
            let got = result, index = turn
            turn = 1 - turn
            // The one after it, into the other buffer, while this one is used.
            if got.count > 0 { read(into: turn) }
            return (buffers[index], got.count, got.error)
        }
    }

    /// Bytes counted from several threads, with a report at most ten times a second.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var sum: Int64 = 0
        private var reported = Date.distantPast
        /// The new sum, when it's time to report it.
        func add(_ bytes: Int64) -> Int64? {
            lock.withLock {
                sum += bytes
                guard Date.now.timeIntervalSince(reported) > 0.1 else { return nil }
                reported = .now
                return sum
            }
        }
    }

    /// A copy's xxHash64, read from the disk (not from memory).
    private func hashFile(_ path: String, read: (Int64) -> Void) throws -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { let code = errno; try checkDrivesAfterFailure(); throw Self.error(code, path) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.chunk, alignment: 16_384)
        defer { buffer.deallocate() }
        var hasher = XXH64()
        while true {
            if isStopping { throw Halt.stop }
            let count = Darwin.read(fd, buffer, Self.chunk)
            if count < 0 { let code = errno; try checkDrivesAfterFailure(); throw Self.error(code, path) }
            if count == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: count))
            read(Int64(count))
        }
        return String(format: "%016llx", hasher.digest())
    }

    private static func error(_ code: Int32, _ path: String) -> NSError {
        // The usual ones in plain words; anything else as the system puts it.
        let message: String? = switch code {
        case EACCES, EPERM: String(localized: "Pluck isn’t allowed to open it.")
        case EIO: String(localized: "It couldn’t be read: the card or drive may be damaged there.")
        case ENOENT: String(localized: "It’s no longer there.")
        case ENAMETOOLONG: String(localized: "Its name is too long for the drive.")
        case EILSEQ: String(localized: "Its name has characters the drive can’t hold.")
        default: nil
        }
        var info: [String: Any] = [NSFilePathErrorKey: path]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: info)
    }

    // MARK: - The report

    /// The list of every file and its hash (MHL 1.1, which Silverstack, OffShoot and Resolve read),
    /// next to the copy.
    private func writeReport(_ target: Int) {
        let iso = ISO8601DateFormatter()
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <tool>Pluck \(version)</tool>
            <startdate>\(iso.string(from: job.started))</startdate>
            <finishdate>\(iso.string(from: .now))</finishdate>
          </creatorinfo>

        """
        for file in job.files where file.done[target] {
            guard let hash = file.hash else { continue }
            xml += """
              <hash>
                <file>\(escaped(file.path))</file>
                <size>\(file.size)</size>
                <lastmodificationdate>\(iso.string(from: file.modified))</lastmodificationdate>
                <xxhash64be>\(hash)</xxhash64be>
                <hashdate>\(iso.string(from: file.hashed ?? .now))</hashdate>
              </hash>

            """
        }
        xml += "</hashlist>\n"
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let report = (job.targets[target] as NSString).appendingPathComponent("\(job.name)_\(stamp.string(from: .now)).mhl")
        try? xml.write(toFile: report, atomically: true, encoding: .utf8)
    }
}

// MARK: - Jobs

/// Every offload, kept on disk; one copies at a time, the others wait their turn.
@MainActor
@Observable
final class OffloadCenter {
    static let shared = OffloadCenter()

    enum State: Equatable {
        case paused, queued, copying, waiting(String), done, stopped(String)
    }

    struct Live: Equatable {
        var bytes: Int64 = 0
        var file = ""
        var checking = false
        /// Bytes a second, smoothed.
        var speed: Double = 0
    }

    private(set) var jobs: [OffloadJob] = []
    private(set) var states: [UUID: State] = [:]
    private(set) var live: [UUID: Live] = [:]
    @ObservationIgnored private var runners: [UUID: OffloadRunner] = [:]
    @ObservationIgnored private var lastSample: [UUID: (Date, Int64)] = [:]
    @ObservationIgnored private var runStarted: [UUID: Date] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [Any] = []

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Offloads", isDirectory: true)
    }

    private init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        jobs = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(OffloadJob.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
        for job in jobs { states[job.id] = job.finished != nil ? .done : .paused }
        // A drive back: the jobs waiting for it carry on.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.drivesChanged() }
        })
    }

    func state(_ job: OffloadJob) -> State { states[job.id] ?? .paused }

    /// A new offload: the files in the source, to a folder named `name` in each of the roots.
    func add(source: URL, roots: [URL], name: String, cascade: Bool = false, eject: Bool = false) async -> String? {
        if let problem = Self.problem(source: source, roots: roots) { return problem }
        let list = await Task.detached(priority: .userInitiated) { Self.files(in: source) }.value
        guard !list.isEmpty else { return String(localized: "There are no files there.") }
        if let problem = Self.problem(files: list, roots: roots) { return problem }
        let job = OffloadJob(name: name, source: source.path, sourceVolume: Self.volumeName(source), roots: roots.map(\.path),
                             rootVolumes: roots.map(Self.volumeName),
                             files: list.map { OffloadFile(path: $0.path, size: $0.size, modified: $0.modified, done: roots.map { _ in false }) },
                             cascade: cascade, ejectSource: eject)
        // Room for it everywhere.
        for root in roots {
            let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
            if free < job.totalBytes { return String(localized: "There isn’t enough room on \(Self.volumeName(root)).") }
        }
        jobs.insert(job, at: 0)
        save(job)
        resume(job.id)
        return nil
    }

    /// Why the source and drives can't be used together, if they can't: a copy inside the card
    /// (it would copy itself), the card inside a copy, or the same place twice.
    nonisolated static func problem(source: URL, roots: [URL]) -> String? {
        let card = source.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") }
        var seen: Set<String> = []
        for root in roots {
            let place = root.standardizedFileURL.resolvingSymlinksInPath().path
            if inside(place, card) { return String(localized: "A copy can’t go inside the card it comes from.") }
            if inside(card, place) { return String(localized: "The card is inside \(volumeName(root)): choose another place for the copy.") }
            if !seen.insert(place).inserted { return String(localized: "\(volumeName(root)) is chosen twice.") }
        }
        return nil
    }

    /// Why these files can't go onto these drives, if they can't: a file over 4 GB for a FAT32
    /// drive, or two names a drive that ignores case would take for one.
    nonisolated static func problem(files: [(path: String, size: Int64, modified: Date)], roots: [URL]) -> String? {
        for root in roots {
            var info = statfs()
            let type = statfs(root.path, &info) == 0
                ? withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
            if type == "msdos", let big = files.first(where: { $0.size >= 4_294_967_296 }) {
                return String(localized: "\((big.path as NSString).lastPathComponent) is over 4 GB, too big for \(volumeName(root)) (a FAT32 drive). Use an exFAT or APFS drive.")
            }
            let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
            if !caseSensitive {
                var names: [String: String] = [:]
                for file in files {
                    let key = file.path.lowercased()
                    if let other = names[key] {
                        return String(localized: "\(other) and \(file.path) would be one file on \(volumeName(root)), which ignores capitals.")
                    }
                    names[key] = file.path
                }
            }
        }
        return nil
    }

    func resume(_ id: UUID) {
        guard runners[id] == nil, let job = jobs.first(where: { $0.id == id }), job.finished == nil else { return }
        states[id] = .queued
        next()
    }

    /// The files that couldn't be copied, once more (the card or a cable may have been at fault).
    func retryProblems(_ id: UUID) {
        guard runners[id] == nil, let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].problems.isEmpty else { return }
        for n in jobs[index].files.indices where jobs[index].files[n].problem != nil {
            jobs[index].files[n].problem = nil
            // Read from the card again (its hash too: a bad read may have been the problem).
            jobs[index].files[n].hash = nil
            jobs[index].files[n].done = jobs[index].files[n].done.map { _ in false }
        }
        jobs[index].finished = nil
        // (A cascade whose card is done reads from the first copy, which needs the file too.)
        jobs[index].cardDone = nil
        save(jobs[index])
        resume(id)
    }

    func pause(_ id: UUID) {
        if let runner = runners[id] {
            runner.stop()
        } else {
            states[id] = .paused
            if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].running == true {
                jobs[index].running = false
                save(jobs[index])
            }
        }
    }

    /// The offloads that were under way when Pluck last stopped, carried on.
    func resumeInterrupted() {
        for job in jobs.reversed() where job.running == true && job.finished == nil { resume(job.id) }
    }

    func remove(_ id: UUID) {
        runners[id]?.stop()
        jobs.removeAll { $0.id == id }
        states[id] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id.uuidString).json"))
    }

    /// The next waiting job, if none is copying.
    private func next() {
        guard runners.isEmpty, let job = jobs.last(where: { states[$0.id] == .queued }) else { return }
        let id = job.id
        states[id] = .copying
        if let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].running != true {
            jobs[index].running = true
            save(jobs[index])
        }
        live[id] = Live()
        lastSample[id] = (.now, job.workDone)
        let runner = OffloadRunner(job: job) { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { OffloadCenter.shared.handle(event, for: id) } }
        }
        runners[id] = runner
        runStarted[id] = .now
        runner.start()
    }

    private func handle(_ event: OffloadRunner.Event, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .progress(let bytes, let file, let phase):
            var now = live[id] ?? Live()
            now.bytes = jobs[index].workDone + bytes
            now.file = file
            now.checking = phase == .checking
            if let (time, done) = lastSample[id], Date.now.timeIntervalSince(time) > 1 {
                let rate = Double(now.bytes - done) / Date.now.timeIntervalSince(time)
                if rate > 0 { now.speed = now.speed == 0 ? rate : now.speed * 0.7 + rate * 0.3 }
                lastSample[id] = (.now, now.bytes)
            }
            live[id] = now
        case .file(let at, let file):
            jobs[index].files[at] = file
            live[id]?.bytes = jobs[index].workDone
            saveSoon(jobs[index])
        case .cardDone:
            jobs[index].cardDone = .now
            save(jobs[index])
            let job = jobs[index]
            AppDelegate.shared?.manager.notify(title: String(localized: "The card is done"),
                                               body: String(localized: "\(job.sourceVolume) is on \(job.rootVolumes[0]) and checked. The other drives copy from there."))
            if job.ejectSource == true { Self.eject(job.source) }
        case .waiting(let drive):
            finish(id, .waiting(drive))
        case .stopped(let problem):
            finish(id, problem.map { .stopped($0) } ?? .paused)
        case .finished:
            jobs[index].finished = .now
            finish(id, .done)
            let job = jobs[index]
            OffloadReport.write(job)
            if job.ejectSource == true, !job.cascades { Self.eject(job.source) }
            let problems = job.problems.count
            AppDelegate.shared?.manager.notify(
                title: problems == 0 ? String(localized: "Offload done") : String(localized: "Offload done, with problems"),
                body: problems == 0 ? String(localized: "\(job.name): every file checked on \(job.roots.count) drives.")
                    : String(localized: "\(job.name): \(problems) files couldn’t be copied."),
                files: job.targets.map { URL(fileURLWithPath: $0) })
        }
    }

    private func finish(_ id: UUID, _ state: State) {
        if let started = runStarted.removeValue(forKey: id), let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].busy = (jobs[index].busy ?? 0) + Date.now.timeIntervalSince(started)
        }
        runners[id] = nil
        live[id] = nil
        states[id] = state
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            // Still meant to happen only while it waits for a drive.
            if case .waiting = state { jobs[index].running = true } else { jobs[index].running = false }
            save(jobs[index])
        }
        next()
    }

    private func drivesChanged() {
        for job in jobs {
            if case .waiting = states[job.id] { resume(job.id) }
        }
    }

    // MARK: Checking a copy

    /// Copies being checked again, or checked (newest first; not kept after quitting).
    private(set) var checks: [OffloadCheck] = []
    /// Checks taken off the list: they stop, even partway through a file.
    private static let stoppedChecks = StoppedChecks()

    final class StoppedChecks: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func insert(_ id: UUID) { lock.withLock { _ = ids.insert(id) } }
        func contains(_ id: UUID) -> Bool { lock.withLock { ids.contains(id) } }
    }

    /// Reads every file in a copy back and compares it with the copy's MHL.
    func check(_ folder: URL) {
        let check = OffloadCheck(folder: folder)
        checks.insert(check, at: 0)
        let id = check.id
        Task.detached(priority: .userInitiated) {
            func update(_ change: @escaping @Sendable (inout OffloadCheck) -> Void) async {
                await MainActor.run {
                    let center = OffloadCenter.shared
                    if let index = center.checks.firstIndex(where: { $0.id == id }) { change(&center.checks[index]) }
                }
            }
            guard let items = MHL.items(in: folder), !items.isEmpty else {
                await update { $0.problem = String(localized: "There’s no MHL file in this folder."); $0.finished = true }
                return
            }
            let total = items.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            await update { $0.total = total }
            var done: Int64 = 0
            var lastReport = Date.distantPast
            for item in items {
                if OffloadCenter.stoppedChecks.contains(id) { break }
                let path = folder.appendingPathComponent(item.path).path
                guard FileManager.default.fileExists(atPath: path) else {
                    await update { $0.missing.append(item.path) }
                    continue
                }
                let base = done
                let hash = MHL.hash(path, kind: item.kind, progress: { bytes in
                    done += bytes
                    if Date.now.timeIntervalSince(lastReport) > 0.2 {
                        lastReport = .now
                        let now = done
                        Task { await update { $0.done = now } }
                    }
                }, stopped: { OffloadCenter.stoppedChecks.contains(id) })
                if OffloadCenter.stoppedChecks.contains(id) { break }
                done = base + (item.size ?? (done - base))
                let now = done
                await update { check in
                    check.done = now
                    if let hash { if hash == item.hash { check.matched += 1 } else { check.changed.append(item.path) } } else { check.unchecked += 1 }
                }
            }
            // On the drive, but not on the list.
            let listed = Set(items.map(\.path))
            let extra = OffloadCenter.files(in: folder).map(\.path).filter { path in
                !listed.contains(path) && !path.hasPrefix("ascmhl/") && !path.lowercased().hasSuffix(".mhl")
                    && !(path.hasSuffix(" Report.pdf") && !path.contains("/"))
            }
            await update { $0.extra = extra; $0.finished = true }
        }
    }

    func removeCheck(_ id: UUID) {
        Self.stoppedChecks.insert(id)
        checks.removeAll { $0.id == id }
    }

    // MARK: Saving

    private func saveSoon(_ job: OffloadJob) {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            saveTask = nil
            if let now = jobs.first(where: { $0.id == job.id }) { save(now) }
        }
    }

    private func save(_ job: OffloadJob) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(job).write(to: Self.folder.appendingPathComponent("\(job.id.uuidString).json"), options: .atomic)
    }

    // MARK: Files and drives

    /// What macOS itself leaves on a drive (indexes, the bin, Finder's notes, resource-fork
    /// copies), never part of what was shot.
    nonisolated static let systemFiles: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".metadata_never_index", ".metadata_never_index_unless_rootfs", ".apdisk", ".VolumeIcon.icns", "Icon\r",
        "System Volume Information", "$RECYCLE.BIN",
    ]

    nonisolated static func isSystemFile(_ name: String) -> Bool {
        systemFiles.contains(name) || name.hasPrefix("._") || name.hasSuffix(".pluckpart")
    }

    /// Every file in a folder, in order: hidden ones too (some cameras hide files a card needs),
    /// but not what macOS itself leaves on a drive.
    nonisolated static func files(in folder: URL) -> [(path: String, size: Int64, modified: Date)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        let base = folder.standardizedFileURL.path
        var found: [(String, Int64, Date)] = []
        while let url = walker.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if isSystemFile(url.lastPathComponent) {
                // (Only for a folder: after a file it would skip the rest of the folder it's in.)
                if values.isRegularFile != true { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            found.append((path, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .now))
        }
        return found.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// A drive's name; a folder's own name when it isn't the whole drive.
    /// Ejects the card the files came from (when they came from a whole card, not a folder).
    static func eject(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              volume.standardizedFileURL.path == url.standardizedFileURL.path else { return }
        Task.detached { try? NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
    }

    /// The drive something is on, by name.
    nonisolated static func driveName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }

    nonisolated static func volumeName(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeURLKey])
        guard let volume = values?.volume, volume.standardizedFileURL.path == url.standardizedFileURL.path else { return url.lastPathComponent }
        return values?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// Cards and other removable drives that are connected.
    nonisolated static func cards() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.filter { volume in
            let values = try? volume.resourceValues(forKeys: Set(keys))
            return values?.volumeIsRemovable == true && values?.volumeIsInternal != true
        }
    }
}

// MARK: - xxHash64

/// xxHash64 (seed 0), fed in pieces: the checksum offload tools use (fast enough to keep up
/// with any drive).
struct XXH64 {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    private var v1 = p1 &+ p2, v2 = p2, v3: UInt64 = 0, v4 = 0 &- p1
    private var held = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
    private var heldCount = 0
    private var total: UInt64 = 0

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }
    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }
    @inline(__always) private static func merge(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        (acc ^ round(0, value)) &* p1 &+ p4
    }

    mutating func update(_ input: UnsafeRawBufferPointer) {
        guard var p = input.baseAddress, input.count > 0 else { return }
        var n = input.count
        total &+= UInt64(n)
        if heldCount + n < 32 {
            withUnsafeMutableBytes(of: &held) { ($0.baseAddress! + heldCount).copyMemory(from: p, byteCount: n) }
            heldCount += n
            return
        }
        if heldCount > 0 {
            let fill = 32 - heldCount
            withUnsafeMutableBytes(of: &held) { ($0.baseAddress! + heldCount).copyMemory(from: p, byteCount: fill) }
            p += fill
            n -= fill
            v1 = Self.round(v1, UInt64(littleEndian: held.0))
            v2 = Self.round(v2, UInt64(littleEndian: held.1))
            v3 = Self.round(v3, UInt64(littleEndian: held.2))
            v4 = Self.round(v4, UInt64(littleEndian: held.3))
            heldCount = 0
        }
        var a = v1, b = v2, c = v3, d = v4
        while n >= 32 {
            a = Self.round(a, UInt64(littleEndian: p.loadUnaligned(as: UInt64.self)))
            b = Self.round(b, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
            c = Self.round(c, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            d = Self.round(d, UInt64(littleEndian: p.loadUnaligned(fromByteOffset: 24, as: UInt64.self)))
            p += 32
            n -= 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d
        if n > 0 {
            withUnsafeMutableBytes(of: &held) { $0.baseAddress!.copyMemory(from: p, byteCount: n) }
            heldCount = n
        }
    }

    func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1); h = Self.merge(h, v2); h = Self.merge(h, v3); h = Self.merge(h, v4)
        } else {
            h = v3 &+ Self.p5
        }
        h &+= total
        let count = heldCount
        withUnsafeBytes(of: held) { raw in
            var i = 0
            while i + 8 <= count {
                h ^= Self.round(0, UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= count {
                h ^= UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < count {
                h ^= UInt64(raw[i]) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33; h &*= Self.p2
        h ^= h >> 29; h &*= Self.p3
        h ^= h >> 32
        return h
    }
}
