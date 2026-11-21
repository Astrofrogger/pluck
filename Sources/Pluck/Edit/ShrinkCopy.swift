import CryptoKit
import Foundation

/// Archive's second copy: before an original counts as safe to delete, a copy of it (its parts and sidecars too)
/// on a second target (another NAS share, an external disk, an LTFS tape, an rclone mount). Each file is hashed
/// as it's read from where it waits, and the copy is read back from the target after its cache is dropped (twice,
/// as a master is: ShrinkFolders.readBack); only the same hash counts. A copy is written as a hidden file and
/// renamed in exclusively (never over anything); one stopped, or cut off when a drive drops out, carries on from
/// what's there and is checked whole. An ASC MHL per project goes beside the copies. It's an option: off
/// unless a default target is chosen in Archive's settings or a project has its own; off, "safe" is the checked master's alone.
extension ShrinkFolders {
    /// A verified second copy of an original: the folder it's in, each file's xxHash64 and size, when.
    struct Copied: Codable, Hashable, Sendable {
        var folder: String
        var target: String
        var hashes: [String: String]
        var sizes: [String: Int64]
        var date: Date
    }

    /// What a project's originals get: a second copy somewhere, or none (the default).
    enum CopyDecision: Equatable, Sendable { case none, target(String) }

    /// The second copy's default target (Archive's settings; nil: none chosen).
    static var defaultCopyTarget: String? {
        get { UserDefaults.standard.string(forKey: "shrinkSecondCopy").flatMap { $0.isEmpty ? nil : $0 } }
        set { UserDefaults.standard.set(newValue, forKey: "shrinkSecondCopy") }
    }

    /// Self-tests: decisions of their own (the owner's settings left alone).
    nonisolated(unsafe) static var decide: ((File) -> CopyDecision)?

    static func copyDecision(project: String, share: String, rules: Rules) -> CopyDecision {
        if let own = rules.copies?[Rules.key(project, share: share)] { return own.isEmpty ? .none : .target(own) }
        return defaultCopyTarget.map { .target($0) } ?? .none
    }

    static func decision(_ file: File, rules: Rules) -> CopyDecision {
        if let decide { return decide(file) }
        return copyDecision(project: file.project.isEmpty ? file.folder : file.project, share: shareRoot(of: URL(fileURLWithPath: file.folder)), rules: rules)
    }

    /// The second copy is all there (the original and each part, at the sizes copied), looked at now.
    static func copyThere(_ file: File) -> Bool {
        guard let copy = file.copied else { return false }
        let names = [(file.path as NSString).lastPathComponent] + file.parts.map { ($0 as NSString).lastPathComponent }
        guard names.allSatisfy({ copy.hashes[$0] != nil && copy.sizes[$0] != nil }) else { return false }
        return copy.sizes.allSatisfy { name, size in
            ((try? FileManager.default.attributesOfItem(atPath: (copy.folder as NSString).appendingPathComponent(name)))?[.size] as? Int64) == size
        }
    }

    /// What "safe to delete" needs beside a checked master: nothing more, or (second copy on for its project) that copy there.
    static func copyOK(_ file: File, _ decision: CopyDecision) -> Bool { decision == .none || copyThere(file) }

    /// Where an original's copy goes: the target, its share's name, and its folders below the share.
    static func copyFolder(_ path: String, folder chosen: String, target: URL) -> String {
        let share = shareRoot(of: URL(fileURLWithPath: chosen))
        let relative = path.hasPrefix(share + "/") ? String(path.dropFirst(share.count + 1)) : (path as NSString).lastPathComponent
        let below = (relative as NSString).deletingLastPathComponent
        let base = target.appendingPathComponent((share as NSString).lastPathComponent.isEmpty ? "Share" : (share as NSString).lastPathComponent, isDirectory: true)
        return below.isEmpty ? base.path : base.appendingPathComponent(below, isDirectory: true).path
    }

    /// A target on the same drive as the original isn't a second copy.
    static func sameDrive(_ a: String, _ b: String) -> Bool {
        func probe(_ path: String) -> URL {
            var url = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
            return url
        }
        let (x, y) = (probe(a), probe(b))
        let (px, py) = (OfficeGroup.place(x)?.remount, OfficeGroup.place(y)?.remount)
        if px != nil || py != nil { return px == py }
        guard let vx = OffloadCenter.volume(x), let vy = OffloadCenter.volume(y) else { return false }
        return vx.isEqual(vy)
    }

    /// Bytes read and written at a time (self-tests: small, to stop halfway).
    nonisolated(unsafe) static var copyChunk = 8 << 20
    /// Self-tests: a copy damaged on its way (after it's written, before it's read back).
    nonisolated(unsafe) static var copyWritten: ((String) -> Void)?

    /// One file copied into `temp` (carrying on from what's there: the whole source is read and hashed again, only the
    /// rest written), flushed to the drive. Gives the source's xxHash64, or why not; `stopped`: asked to stop (temp kept).
    static func copyPiece(_ from: String, to temp: String, stop: () -> Bool) -> (hash: String?, problem: String?, stopped: Bool) {
        let name = (from as NSString).lastPathComponent
        let source = Darwin.open(from, O_RDONLY)
        guard source >= 0 else { return (nil, String(localized: "\(name) can’t be read"), false) }
        defer { close(source) }
        _ = fcntl(source, F_NOCACHE, 1)
        var info = stat()
        guard fstat(source, &info) == 0 else { return (nil, String(localized: "\(name) can’t be read"), false) }
        let total = Int64(info.st_size)
        var have: Int64 = 0, there = stat()
        if lstat(temp, &there) == 0 {
            have = (there.st_mode & S_IFMT) == S_IFREG ? Int64(there.st_size) : -1
            if have > total || have <= 0 { unlink(temp); have = 0 }
        }
        let out = Darwin.open(temp, have > 0 ? O_WRONLY : (O_WRONLY | O_CREAT | O_EXCL), 0o644)
        guard out >= 0 else { return (nil, String(localized: "Can’t write the second copy: \(String(cString: strerror(errno)))"), false) }
        defer { close(out) }
        guard ftruncate(out, have) == 0, lseek(out, have, SEEK_SET) == have else { return (nil, String(localized: "Can’t write the second copy: \(String(cString: strerror(errno)))"), false) }
        var xxh = XXH64(), done: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: max(copyChunk, 4096))
        while true {
            if stop() { return (nil, nil, true) }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source, $0.baseAddress, $0.count) }
            if count < 0 { return (nil, String(localized: "Reading \(name) stopped: \(String(cString: strerror(errno)))"), false) }
            if count == 0 { break }
            buffer.withUnsafeBytes { xxh.update(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            // (Only what isn't in the hidden copy yet is written.)
            let skip = Int(max(min(have - done, Int64(count)), 0))
            var offset = skip
            while offset < count {
                let wrote = buffer.withUnsafeBytes { Darwin.write(out, $0.baseAddress! + offset, count - offset) }
                if wrote <= 0 { return (nil, String(localized: "Writing the second copy stopped: \(String(cString: strerror(errno)))"), false) }
                offset += wrote
            }
            done += Int64(count)
        }
        guard done == total else { return (nil, String(localized: "\(name) changed while it was copied"), false) }
        guard flush(temp) else { return (nil, String(localized: "The second copy couldn’t be written to the drive"), false) }
        return (String(format: "%016llx", xxh.digest()), nil, false)
    }

    /// An original's second copy into `target`, with its parts and sidecars: read where it waits (the folder to delete,
    /// or its own place for a run into another folder), all of it there and as it was when its master was made; each
    /// piece goes in as a new file only (a piece already there with the same bytes counts, anything else is left and
    /// said). Gives the file with `copied` set, or with `copyProblem`; `stopped`: carry on from there next time.
    static func secondCopy(_ file: File, target: URL, token: String, stop: () -> Bool = { false }) -> (file: File, stopped: Bool) {
        var file = file
        let fm = FileManager.default
        func fail(_ why: String, stopped: Bool = false) -> (file: File, stopped: Bool) { file.copyProblem = why; return (file, stopped) }
        func size(_ path: String) -> Int64? { (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 }
        guard file.state == .done, file.master != nil else { return fail(String(localized: "Only an original with its master made gets a second copy")) }
        let source = file.moved ?? file.path, from = (source as NSString).deletingLastPathComponent
        let main = (file.path as NSString).lastPathComponent
        guard fm.fileExists(atPath: target.path) else { return fail(String(localized: "\(target.lastPathComponent) isn’t there: connect it"), stopped: true) }
        guard fm.fileExists(atPath: source) else {
            // (Its share not mounted: nothing to say yet. Its folder there but the original gone: deleted already.)
            if !fm.fileExists(atPath: from) { return fail(String(localized: "Its share isn’t mounted"), stopped: true) }
            return fail(String(localized: "The original isn’t there any more"))
        }
        guard !sameDrive(source, target.path) else { return fail(String(localized: "A second copy has to go to another drive or share")) }
        let parts = file.parts.map { ($0 as NSString).lastPathComponent }
        let sidecars = (file.sidecars ?? []).map { ($0 as NSString).lastPathComponent }
            .filter { $0 != main && !parts.contains($0) && fm.fileExists(atPath: (from as NSString).appendingPathComponent($0)) }
        let sizes = ([main] + parts).map { size((from as NSString).appendingPathComponent($0)) }
        guard !sizes.contains(where: { $0 == nil }), sizes.reduce(Int64(0), { $0 + ($1 ?? 0) }) == file.size else {
            return fail(String(localized: "The original isn’t all there"))
        }
        if let head = file.originalHead, headHash(source) != head { return fail(String(localized: "The original changed")) }
        let folder = copyFolder(file.path, folder: file.folder, target: target)
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: folder) else { return fail(String(localized: "Read-only: no permission to write to \(target.lastPathComponent)")) }
        var hashes: [String: String] = [:], bytes: [String: Int64] = [:]
        for name in [main] + parts + sidecars {
            let piece = (from as NSString).appendingPathComponent(name), place = (folder as NSString).appendingPathComponent(name)
            let want = size(piece) ?? -1
            if placeholder(place) { unlink(place) }
            if fm.fileExists(atPath: place) {
                // Never over it: one with the same bytes (made before a quit) is this copy; anything else stays as it is.
                let here = readBack(piece).hash, there = readBack(place).hash
                guard let there, there == here, size(place) == want else {
                    return fail(String(localized: "Something else is where the second copy of \(name) goes: left as it is"))
                }
                (hashes[name], bytes[name]) = (there, want)
                continue
            }
            let temp = (folder as NSString).appendingPathComponent(".pluck-copying-\(token)-\(name)")
            let copied = copyPiece(piece, to: temp, stop: stop)
            if copied.stopped { file.copyProblem = nil; return (file, true) }
            guard let hash = copied.hash else { return fail(copied.problem ?? String(localized: "The second copy couldn’t be made")) }
            copyWritten?(temp)
            // Read back from the target, not this Mac's cache: only the same bytes go in.
            guard readBack(temp).hash == hash else {
                unlink(temp)
                return fail(String(localized: "The second copy of \(name) read back differently: it’s made again next time"))
            }
            if let why = rename(temp, place) { unlink(temp); return fail(why) }
            guard size(place) == want else { return fail(String(localized: "The second copy of \(name) isn’t whole")) }
            (hashes[name], bytes[name]) = (hash, want)
        }
        // (Still the original it was: a file changed meanwhile isn't counted as copied.)
        if let head = file.originalHead, headHash(source) != head { return fail(String(localized: "The original changed")) }
        file.copied = Copied(folder: folder, target: target.path, hashes: hashes, sizes: bytes, date: .now)
        file.copyProblem = nil
        return (file, false)
    }

    // MARK: ASC MHL

    /// A C4 ID (SMPTE ST 2114): SHA-512 in base58, 88 characters after "c4".
    static func c4(_ data: Data) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var number = Array(SHA512.hash(data: data)).map(Int.init)
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var remainder = 0, next: [Int] = []
            for byte in number {
                let value = remainder * 256 + byte
                next.append(value / 58)
                remainder = value % 58
            }
            digits.append(alphabet[remainder])
            number = next
        }
        let text = String(digits.reversed())
        return "c4" + String(repeating: "1", count: max(88 - text.count, 0)) + text
    }

    /// A new ASC MHL generation in `root`/ascmhl listing these files (paths below root), and the chain updated.
    /// Never over an earlier generation: each gets its own number.
    @discardableResult
    static func writeASCMHL(root: URL, files: [(path: String, size: Int64, modified: Date, hash: String)], now: Date = .now) throws -> URL {
        let folder = root.appendingPathComponent("ascmhl", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        func xml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(iso.string(from: now))</creationdate>
            <hostname>\(xml(Host.current().localizedName ?? "Mac"))</hostname>
            <tool version="\(xml(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"))">Pluck</tool>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
          </processinfo>
          <hashes>

        """
        for file in files.sorted(by: { $0.path < $1.path }) {
            body += """
                <hash>
                  <path size="\(file.size)" lastmodificationdate="\(iso.string(from: file.modified))">\(xml(file.path))</path>
                  <xxh64 action="original" hashdate="\(iso.string(from: now))">\(file.hash)</xxh64>
                </hash>

            """
        }
        body += "  </hashes>\n</hashlist>\n"
        let data = Data(body.utf8)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let taken = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap { Int($0.prefix(4)) }
        var number = (taken.max() ?? 0) + 1, made: URL?
        let name = FolderTemplate.safe(root.lastPathComponent).isEmpty ? "Copy" : FolderTemplate.safe(root.lastPathComponent)
        for _ in 0..<20 {
            let url = folder.appendingPathComponent(String(format: "%04d", number) + "_\(name)_\(stamp.string(from: now))Z.mhl")
            let handle = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if handle < 0 { number += 1; continue }
            let wrote = data.withUnsafeBytes { Darwin.write(handle, $0.baseAddress, $0.count) }
            close(handle)
            guard wrote == data.count, flush(url.path) else { throw CocoaError(.fileWriteUnknown) }
            made = url
            break
        }
        guard let made else { throw CocoaError(.fileWriteFileExists) }
        // The chain: every generation in order with its C4 ID.
        let chain = folder.appendingPathComponent("ascmhl_chain.xml")
        let old = (try? String(contentsOf: chain, encoding: .utf8)) ?? ""
        var entries = old.components(separatedBy: "<hashlist ").dropFirst().map { "<hashlist " + ($0.components(separatedBy: "</hashlist>").first ?? "") + "</hashlist>" }
        entries.append("<hashlist sequencenr=\"\(number)\">\n    <path>\(xml(made.lastPathComponent))</path>\n    <c4>\(c4(data))</c4>\n  </hashlist>")
        let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ascmhldirectory xmlns=\"urn:ASC:MHL:DIRECTORY:v2.0\">\n  " + entries.joined(separator: "\n  ") + "\n</ascmhldirectory>\n"
        try text.write(to: chain, atomically: true, encoding: .utf8)
        return made
    }
}

extension ShrinkCenter {
    /// Where a file's second copy goes now (nil: none, or not decided).
    func copyTarget(_ file: ShrinkFolders.File, in run: ShrinkFolders.Run, rules: ShrinkFolders.Rules) -> String? {
        if let given = run.copyTargets?[file.project] { return given.isEmpty ? nil : given }
        if case .target(let path) = ShrinkFolders.decision(file, rules: rules) { return path }
        return nil
    }

    /// Second copies of a run's originals (`project`: only that project's; `target`: there instead), each where its
    /// project's go, one at a time, waiting while someone edits and never for a project on hold. A stop, a quit or a
    /// target that's gone carries on next time. Then an ASC MHL per project. Gives what stopped it (nil: through).
    @discardableResult
    /// (`retry`: also the files whose last copy failed; else only those not tried yet or stopped.)
    func secondCopies(_ id: UUID, project: String? = nil, target given: String? = nil, retry: Bool = true) async -> String? {
        guard copying == nil, active == nil, checking == nil, run(id) != nil else { return nil }
        guard mounted(id), let run = run(id) else { return self.run(id)?.paused }
        copying = id
        stopCopies = false
        defer { copying = nil; copyingNow = nil }
        let rules = ShrinkFolders.Rules.load()
        let token = String(install.prefix(8)), mac = claimName
        var listed: [String: [(path: String, size: Int64, modified: Date, hash: String)]] = [:]
        var stopped: String?
        for file in run.files where file.state == .done && (project == nil || file.project == project) && (retry || file.copyProblem == nil)
            && !ShrinkFolders.copyThere(file) {
            guard let target = given ?? copyTarget(file, in: run, rules: rules) else { continue }
            let projectFolder = file.project.isEmpty ? file.folder : file.project
            if await Task.detached(priority: .utility, operation: { ArchiveProject.read(projectFolder)?.hold == true }).value { continue }
            let place = (ShrinkFolders.copyFolder(file.path, folder: file.folder, target: URL(fileURLWithPath: target)) as NSString)
                .appendingPathComponent((file.path as NSString).lastPathComponent)
            var result: (file: ShrinkFolders.File, stopped: Bool)?, editedOff = false
            repeat {
                editedOff = false
                // (Someone editing from that share: wait until it's been quiet a while.)
                var quietSince: Date?
                while !stopCopies, !runAnyway {
                    if await editing(file.folder) { quietSince = nil } else if let since = quietSince { if Date.now.timeIntervalSince(since) >= editQuiet { break } } else { quietSince = .now; if editQuiet <= 0 { break } }
                    try? await Task.sleep(for: .seconds(min(5, max(editCheck / 4, 0.2))))
                }
                if stopCopies { break }
                // (Never made: a target that isn't there would be a new folder on this Mac's own disk.)
                guard FileManager.default.fileExists(atPath: target) else {
                    stopped = String(localized: "\((target as NSString).lastPathComponent) isn’t there: connect it"); break
                }
                if let free = freeSpace(URL(fileURLWithPath: target)), free < file.size + 1_000_000_000 {
                    stopped = String(localized: "\((target as NSString).lastPathComponent) is nearly full: second copies paused"); break
                }
                // Claimed first, so two Macs never write the same copy.
                let claim = await Task.detached { () -> OfficeGroup.Claim? in
                    let url = URL(fileURLWithPath: place)
                    if let claim = OfficeGroup.claim(url, mac: mac) { return claim }
                    if let holder = OfficeGroup.holder(OfficeGroup.claimURL(url)), holder.mac == mac { unlink(OfficeGroup.claimURL(url).path); return OfficeGroup.claim(url, mac: mac) }
                    return nil
                }.value
                guard let claim else { break }
                let flag = StopFlag(), edited = StopFlag()
                let folder = file.folder
                let watch = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(max(editCheck, 0.2)))
                        if Task.isCancelled { return }
                        if stopCopies { flag.value = true; return }
                        if !runAnyway, await editing(folder) { edited.value = true; flag.value = true; return }
                    }
                }
                let renewing = Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(OfficeGroup.claimRenewal))
                        if !Task.isCancelled { OfficeGroup.renew(claim) }
                    }
                }
                copyingNow = file.path
                let current = self.run(id)?.files.first(where: { $0.path == file.path }) ?? file
                result = await Task.detached(priority: .utility) {
                    ShrinkFolders.secondCopy(current, target: URL(fileURLWithPath: target), token: token, stop: { flag.value })
                }.value
                watch.cancel()
                renewing.cancel()
                OfficeGroup.release(claim)
                // (Stopped for editing: carried on from the hidden copy once it's quiet again.)
                editedOff = result?.stopped == true && edited.value && !stopCopies
            } while editedOff
            guard let result else {
                if stopCopies, stopped == nil { stopped = String(localized: "Second copies paused") }
                if stopped != nil { break }
                continue
            }
            // (Only the copy's fields: whatever else changed meanwhile stays.)
            if var now = self.run(id)?.files.first(where: { $0.path == file.path }) {
                now.copied = result.file.copied ?? now.copied
                // (A stop or a drive that's gone isn't a failure: tried again next time.)
                now.copyProblem = result.stopped ? nil : result.file.copyProblem
                set(now, in: id)
            }
            if let made = result.file.copied {
                let root = ShrinkFolders.copyRoot(projectFolder, folder: file.folder, target: URL(fileURLWithPath: target), copy: made.folder)
                for (name, hash) in made.hashes {
                    let path = (made.folder as NSString).appendingPathComponent(name)
                    let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .now
                    listed[root, default: []].append((String(path.dropFirst(root.count + 1)), made.sizes[name] ?? 0, modified, hash))
                }
            }
            if result.stopped { stopped = result.file.copyProblem ?? String(localized: "Second copies paused"); break }
            if stopped != nil { break }
        }
        for (root, files) in listed where !files.isEmpty {
            _ = await Task.detached(priority: .utility) { try? ShrinkFolders.writeASCMHL(root: URL(fileURLWithPath: root), files: files) }.value
        }
        if !listed.isEmpty { await catalogue(id, ffmpeg: nil) }
        return stopped
    }
}

extension ShrinkCenter {
    /// A run's projects' catalogues brought up to date (thumbnails made when `ffmpeg` is given).
    func catalogue(_ id: UUID, ffmpeg: String?) async {
        guard let files = run(id)?.files else { return }
        await Task.detached(priority: .utility) { ArchiveCatalog.update(files, ffmpeg: ffmpeg) }.value
    }
}

extension ShrinkFolders {
    /// The project's folder at the target (where its ASC MHL goes); a copy outside it: its own folder.
    static func copyRoot(_ project: String, folder chosen: String, target: URL, copy: String) -> String {
        let root = copyFolder((project as NSString).appendingPathComponent("x"), folder: chosen, target: target)
        return copy == root || copy.hasPrefix(root + "/") ? root : copy
    }
}

// MARK: Restore Originals

extension ShrinkFolders {
    /// An original brought back from its second copy to its own place (its parts beside it): each piece copied next to
    /// where it goes as a hidden file, its hash read back the same as the copy's, then renamed in exclusively (all or none),
    /// never over anything; a master with the original's name is set aside first (and back if anything fails), then to
    /// the Trash. A stop carries on from the hidden pieces. Gives the file put back (`restored`) or with `problem`.
    static func restoreFromCopy(_ file: File, token: String, stop: () -> Bool = { false },
                                trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> (file: File, stopped: Bool) {
        var file = file
        let fm = FileManager.default
        func fail(_ why: String) -> (file: File, stopped: Bool) { file.problem = why; return (file, false) }
        func size(_ path: String) -> Int64? { (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 }
        guard file.state == .done, let master = file.master, let copy = file.copied else { return fail(String(localized: "There’s no second copy to restore from")) }
        guard copyThere(file) else { return fail(String(localized: "The second copy isn’t all there")) }
        let pieces = [file.path] + file.parts
        let folder = (file.path as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: folder) else { return (fail(String(localized: "Its share isn’t mounted")).file, true) }
        if let free = OffloadCenter.freeSpace(URL(fileURLWithPath: folder)), free < file.size + headroom(capacity(URL(fileURLWithPath: folder))) {
            return fail(String(localized: "Not enough free space to restore the original"))
        }
        // (Whatever is at a piece's place that isn't this master stays: nothing is ever written over.)
        for piece in pieces where piece != master && fm.fileExists(atPath: piece) && !placeholder(piece) {
            return fail(String(localized: "Something is at the original’s place: left as it is"))
        }
        var moves: [(String, String)] = []
        for piece in pieces {
            let name = (piece as NSString).lastPathComponent
            guard let hash = copy.hashes[name] else { return fail(String(localized: "The second copy isn’t all there")) }
            let temp = ((piece as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".pluck-restoring-\(token)-\(name)")
            let made = copyPiece((copy.folder as NSString).appendingPathComponent(name), to: temp, stop: stop)
            if made.stopped { return (file, true) }
            guard made.hash == hash, readBack(temp).hash == hash else {
                unlink(temp)
                return fail(made.problem ?? String(localized: "The restored original read back differently: try again"))
            }
            moves.append((temp, piece))
        }
        // A master under the original's name: set aside (only this master) before the original goes in.
        var aside: String?
        if fm.fileExists(atPath: master), pieces.contains(master) {
            guard size(master) == file.masterSize, file.masterHash == nil || readBack(master).hash == file.masterHash else {
                return fail(String(localized: "The file at the master’s name isn’t this master: left as it is"))
            }
            let hidden = (folder as NSString).appendingPathComponent(".pluck-removed-\(UUID().uuidString.prefix(8))-" + (master as NSString).lastPathComponent)
            if let why = rename(master, hidden) { return fail(why) }
            aside = hidden
        }
        pieces.forEach { if placeholder($0) { unlink($0) } }
        if let why = moveAll(moves) {
            if let aside, rename(aside, master) != nil {
                return fail(String(localized: "Couldn’t restore the original: \(why). The master is hidden next to it as \((aside as NSString).lastPathComponent)"))
            }
            return fail(String(localized: "Couldn’t restore the original: \(why)"))
        }
        // The master (a different name) goes too, as Put Back does; set aside first so only this master ever goes.
        if aside == nil, fm.fileExists(atPath: master), master != file.path {
            if size(master) == file.masterSize, file.masterHash == nil || readBack(master).hash == file.masterHash {
                let hidden = (folder as NSString).appendingPathComponent(".pluck-removed-\(UUID().uuidString.prefix(8))-" + (master as NSString).lastPathComponent)
                if rename(master, hidden) == nil { aside = hidden }
            }
        }
        if let aside, (try? trash(URL(fileURLWithPath: aside))) == nil {
            file.note = String(localized: "The master is hidden next to it as \((aside as NSString).lastPathComponent)")
        }
        file.state = .restored
        file.problem = nil
        return (file, false)
    }
}

extension ShrinkCenter {
    /// Restore Originals for a project of a run: each original from the folder to delete (as Put Back, its first and last MB
    /// the same as when its master was made), or else from its second copy, back at its place; checked by hash, never over
    /// anything. Then its catalogue; Relink to Originals in History points Resolve back. Gives what stopped it (nil: through).
    @discardableResult
    func restore(_ id: UUID, project: String) async -> String? {
        guard copying == nil, active == nil, checking == nil, run(id) != nil else { return nil }
        guard mounted(id), let run = run(id) else { return self.run(id)?.paused }
        copying = id
        stopCopies = false
        defer { copying = nil; copyingNow = nil }
        let token = String(install.prefix(8)), settings = run.settings, trash = trash
        var stopped: String?
        for file in run.files where file.state == .done && (file.project.isEmpty ? file.folder : file.project) == project {
            copyingNow = file.path
            let flag = StopFlag()
            let watch = Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(0.5)); if stopCopies { flag.value = true; return } } }
            let result: (file: ShrinkFolders.File, stopped: Bool) = await Task.detached(priority: .utility) {
                if let moved = file.moved, FileManager.default.fileExists(atPath: moved) {
                    // (From the folder to delete: only the original it was.)
                    if let head = file.originalHead, ShrinkFolders.headHash(moved) != head {
                        var kept = file
                        kept.problem = String(localized: "The original in the folder to delete changed: not put back")
                        return (kept, false)
                    }
                    return (ShrinkFolders.putBack(file, settings: settings, trash: trash), false)
                }
                return ShrinkFolders.restoreFromCopy(file, token: token, stop: { flag.value }, trash: trash)
            }.value
            watch.cancel()
            set(result.file, in: id)
            if result.stopped { stopped = result.file.problem ?? String(localized: "Restore paused"); break }
        }
        await catalogue(id, ffmpeg: nil)
        return stopped
    }
}
