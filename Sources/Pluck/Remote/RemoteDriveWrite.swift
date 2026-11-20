import CryptoKit
import Darwin
import Foundation

// Writing to the Edit Anywhere drive (4.0.7). Design, around the reasons the access plan (§5) gave against it:
//
// - Never in place. NFS calls only touch a local overlay on this Mac (Application Support, not Caches: it must outlive a
//   restart): new files' bytes in a spool, plus a small state file. A file goes to the office whole, after a quiet
//   period (or COMMIT), through `driveWrite`: the hidden partial + SHA-256 of Send Files Here (RemoteSendInto.receive),
//   then published by one rename. A dropped link leaves the office as it was; the upload resumes from `driveWriteState`.
// - No locking across Macs (no NLM): a writable mount keeps locks on this Mac (`locallocks`), and the office never
//   overwrites blindly. Each upload says which office version it replaces (size + modification time this Mac last
//   sent or knew). Changed meanwhile, or already there for a new file: the office keeps its file and saves this one as
//   "Name (Mac's name).ext"; the user is told. Replacing an unchanged one keeps the old one in `.pluck-versions`.
// - Deletes and renames go as actions too; a delete moves to the share's `.pluck-trash`. Both hidden folders are dated
//   per day and emptied after N days (office setting, default 7). Nothing is ever hard-deleted by a home Mac.
// - Junk never travels: macOS's (.DS_Store, ._*, .Spotlight-V100, .fseventsd, .Trashes) and Resolve's caches (CacheClip,
//   .gallery, OptimizedMedia, ProxyMedia, *.lck), any hidden name, and names the office can't take stay in the overlay.
// - Rights per action, per folder: Editor or Admin in that folder (`\.render`, as Send Files Here). The drive asks
//   `driveCanWrite` per folder (cached, kept for offline); other folders answer EACCES. The proxies themselves are
//   never writable. An office from before (driveInfo without `write`) gets a read-only mount and a one-line reason.
// - Offline: writes go to the overlay and wait; the queue survives restarts and goes when the office answers again.
//
// shortcut: the drive shows the office's proxies plus the files this Mac wrote (not other Macs' writes or other office
// files); add a listing of the share's non-media files if editors need to open each other's saves.

// MARK: - The office's side

@MainActor
enum RemoteDriveWriteHost {
    /// Days replaced and deleted files stay in a share's hidden versions and trash folders.
    nonisolated static let keepKey = "editAnywhereKeepDays"
    nonisolated static var keepDays: Int { max(1, UserDefaults.standard.object(forKey: keepKey) as? Int ?? 7) }
    nonisolated static let versionsName = ".pluck-versions", trashName = ".pluck-trash"
    /// Said in driveInfo (`write`): this office takes writes from the drive. (A variable for the test of an older office.)
    nonisolated(unsafe) static var offered = true

    static func register() {
        // {share, path (a folder)} → {can}: whether this Mac may write in it.
        OfficeActions.register("driveCanWrite") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"])
            let folder = try OfficeActions.require(\.browse, device, share: place, path: try OfficeActions.text(arguments["path"], empty: true))
            return ["can": RemoteEditHost.isDirectory(folder) && OfficeActions.allowed(\.render, device, share: place, file: folder)]
        }
        // {share, path} → {made}: a folder (one that's there already is fine).
        OfficeActions.register("driveFolder") { arguments, device in
            let (folder, name) = try target(arguments, device)
            let made = folder.appendingPathComponent(name)
            if mkdir(made.path, 0o755) != 0, !(errno == EEXIST && RemoteEditHost.isDirectory(made)) { throw OfficeInbox.Problem.badPath }
            return ["made": true]
        }
        // {share, path, size, modified} → {have}
        OfficeActions.register("driveWriteState") { arguments, device in
            let (folder, name) = try target(arguments, device)
            let size = try OfficeActions.number(arguments["size"]), modified = arguments["modified"] as? Double ?? 0
            let part = RemoteSendInto.partial(folder, name: name, size: size, modified: modified)
            return ["have": (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? 0]
        }
        // … plus {offset, data, sha256 (last piece), baseSize, baseModified (the office file it replaces)}
        //   → {have} or, placed: {have, name, size, modified, conflict}
        OfficeActions.register("driveWrite") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"])
            let (folder, name) = try target(arguments, device)
            let size = try OfficeActions.number(arguments["size"]), modified = (arguments["modified"] as? Double ?? 0).rounded()
            guard size <= RemoteSendInto.largest else { throw OfficeInbox.Problem.tooBig }
            guard let data = (arguments["data"] as? String).flatMap({ Data(base64Encoded: $0) }), data.count <= OfficeLink.uploadChunk else {
                throw OfficeActions.incomplete()
            }
            let offset = try OfficeActions.number(arguments["offset"]), sha = arguments["sha256"] as? String
            let base = stamp(arguments), mac = device.name, root = place.root
            return try await Task.detached {
                try RemoteSendInto.receive(into: folder, name: name, size: size, modified: modified, offset: offset, data: data, sha256: sha) { part in
                    try publish(part, root: root, folder: folder, name: name, modified: modified, base: base, mac: mac)
                }
            }.value
        }
        // {share, path, baseSize?, baseModified?} → {trashed} (false: changed at the office since, kept there)
        OfficeActions.register("driveRemove") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"])
            let file = try OfficeActions.require(\.render, device, share: place, path: try OfficeActions.text(arguments["path"]))
            guard RemoteEditHost.relative(file, in: place.root) != "" else { throw OfficeActions.incomplete() }
            let base = stamp(arguments)
            return ["trashed": try await Task.detached { try remove(file, root: place.root, base: base) }.value]
        }
        // {share, path (from), to, baseSize?, baseModified? (the file at `to` as this Mac knows it)} → {name, conflict}
        OfficeActions.register("driveRename") { arguments, device in
            let place = try RemoteEditHost.share(arguments["share"])
            let from = try OfficeActions.require(\.render, device, share: place, path: try OfficeActions.text(arguments["path"]))
            var moved = arguments
            moved["path"] = arguments["to"]
            let (folder, name) = try target(moved, device)
            let base = stamp(arguments), mac = device.name, root = place.root
            return try await Task.detached { try rename(from, root: root, folder: folder, name: name, base: base, mac: mac) }.value
        }
    }

    /// The folder (resolved in the share, where this Mac is an Editor) and the checked name of `path`'s last part.
    private static func target(_ arguments: [String: Any], _ device: OfficeRenderServer.Device) throws -> (URL, String) {
        let place = try RemoteEditHost.share(arguments["share"])
        let path = try OfficeActions.text(arguments["path"])
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let folder = try OfficeActions.require(\.render, device, share: place, path: parent, refusal: OfficeActions.sendRefusal)
        guard RemoteEditHost.isDirectory(folder) else { throw OfficeActions.incomplete() }
        guard RemoteSendInto.nameOK(name) else { throw OfficeInbox.Problem.badPath }
        return (folder, name)
    }

    nonisolated private static func stamp(_ arguments: [String: Any]) -> RemoteDriveOverlay.Stamp? {
        guard let size = (arguments["baseSize"] as? NSNumber)?.int64Value, let modified = arguments["baseModified"] as? Double else { return nil }
        return RemoteDriveOverlay.Stamp(size: size, modified: modified)
    }

    /// A file's size and whole-second modification time (nil: not a plain file).
    nonisolated static func stamp(of file: URL) -> RemoteDriveOverlay.Stamp? {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return RemoteDriveOverlay.Stamp(size: Int64(info.st_size), modified: Double(info.st_mtimespec.tv_sec))
    }

    nonisolated private static func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }

    /// "Name (Mac).ext": where this Mac's copy goes when the office's changed meanwhile.
    nonisolated static func conflictName(_ name: String, mac: String) -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        let who = String(Folders.sanitize(mac, fallback: "Mac").prefix(40))
        let base = String(stem.prefix(120 - who.count - ext.count - 5))
        return "\(base) (\(who))" + (ext.isEmpty ? "" : "." + ext)
    }

    /// The first of "Name", "Name 2", … that isn't taken in the folder.
    nonisolated private static func freeName(_ name: String, in folder: URL) -> String {
        let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for n in 1...1000 {
            let candidate = n == 1 ? name : "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
            if !exists(folder.appendingPathComponent(candidate)) { return candidate }
        }
        return "\(stem) \(UUID().uuidString.prefix(8))" + (ext.isEmpty ? "" : "." + ext)
    }

    /// The received file in place: over the office's file when it's the one this Mac replaces (kept in versions first),
    /// else beside it as "Name (Mac).ext". A file that's gone at the office meanwhile is simply made again.
    nonisolated static func publish(_ part: URL, root: URL, folder: URL, name: String, modified: Double,
                                    base: RemoteDriveOverlay.Stamp?, mac: String) throws -> [String: Any] {
        let target = folder.appendingPathComponent(name)
        var placed = name, conflict = false
        if exists(target) {
            if let base, let now = stamp(of: target), now == base {
                try stash(target, root: root, into: versionsName, stamped: true)
                guard Darwin.rename(part.path, target.path) == 0 else { throw OfficeInbox.Problem.badPath }
            } else {
                placed = try RemoteSendInto.place(part, in: folder, name: conflictName(name, mac: mac))
                conflict = true
            }
        } else {
            placed = try RemoteSendInto.place(part, in: folder, name: name)
            conflict = placed != name
        }
        let file = folder.appendingPathComponent(placed)
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
        cleanup(root)
        let now = stamp(of: file) ?? RemoteDriveOverlay.Stamp(size: 0, modified: modified)
        return ["name": placed, "size": now.size, "modified": now.modified, "conflict": conflict]
    }

    /// Into the share's trash (a folder only when empty but for macOS's own files). False: the file changed at the office
    /// since this Mac knew it, so it stays.
    nonisolated static func remove(_ file: URL, root: URL, base: RemoteDriveOverlay.Stamp?) throws -> Bool {
        if RemoteEditHost.isDirectory(file) {
            let left = ((try? FileManager.default.contentsOfDirectory(atPath: file.path)) ?? []).filter { $0 != ".DS_Store" && !$0.hasPrefix("._") }
            guard left.isEmpty else { throw OfficeLink.Failure.office(String(localized: "That folder isn’t empty at the office, so it stays.")) }
        } else if let base, stamp(of: file) != base {
            return false
        }
        try stash(file, root: root, into: trashName, stamped: false)
        cleanup(root)
        return true
    }

    nonisolated static func rename(_ from: URL, root: URL, folder: URL, name: String, base: RemoteDriveOverlay.Stamp?, mac: String) throws -> [String: Any] {
        var target = folder.appendingPathComponent(name), conflict = false
        if exists(target) {
            if let base, let now = stamp(of: target), now == base, !RemoteEditHost.isDirectory(from) {
                try stash(target, root: root, into: versionsName, stamped: true)
            } else {
                target = folder.appendingPathComponent(freeName(conflictName(name, mac: mac), in: folder))
                conflict = true
            }
        }
        guard Darwin.rename(from.path, target.path) == 0 else { throw OfficeInbox.Problem.badPath }
        return ["name": target.lastPathComponent, "conflict": conflict]
    }

    /// Moves a file or folder into <share>/<hidden>/<day>/<its folder in the share>/ (a version gets the time in its name).
    nonisolated static func stash(_ item: URL, root: URL, into hidden: String, stamped: Bool) throws {
        let base = URL(fileURLWithPath: RemoteEditHost.realPath(root.path) ?? root.path, isDirectory: true)
        let relative = RemoteEditHost.relative(item, in: root)
        let day = DateFormatter(), time = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"; time.dateFormat = "HHmmss"
        day.locale = Locale(identifier: "en_US_POSIX"); time.locale = day.locale
        let folder = base.appendingPathComponent(hidden).appendingPathComponent(day.string(from: .now))
            .appendingPathComponent((relative as NSString).deletingLastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = item.lastPathComponent
        if stamped {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            name = "\(stem) \(time.string(from: .now))" + (ext.isEmpty ? "" : "." + ext)
        }
        guard Darwin.rename(item.path, folder.appendingPathComponent(freeName(name, in: folder)).path) == 0 else { throw OfficeInbox.Problem.badPath }
    }

    /// Days older than `keepDays` leave the share's versions and trash.
    nonisolated static func cleanup(_ root: URL, now: Date = .now) {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        let oldest = now.addingTimeInterval(-Double(keepDays) * 86_400)
        for hidden in [versionsName, trashName] {
            let folder = root.appendingPathComponent(hidden)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let date = day.date(from: name), date.addingTimeInterval(86_400) < oldest else { continue }
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}

// MARK: - This Mac's overlay

/// One share's writes on this Mac: what the drive shows besides the office's proxies, the bytes not sent yet, and the
/// office-side deletes and renames waiting. Saved in Application Support so nothing unsent is lost with a restart.
final class RemoteDriveOverlay: @unchecked Sendable {
    /// An office file as this Mac knows it: replacing it is only allowed while it's still this.
    struct Stamp: Codable, Equatable, Sendable { var size: Int64; var modified: Double }
    enum State: String, Codable { case local, pending, sent, refused }

    struct Item: Codable {
        var folder: Bool
        var size: Int64 = 0
        var modified = Date.now
        /// Its bytes on this Mac (a file name in the spool; nil: only at the office, or a folder).
        var spool: String?
        /// Its path at the office once sent (a conflict copy's differs from the drive's).
        var remote: String?
        var base: Stamp?
        var state: State
        /// Refused: the office's words.
        var note: String?
        /// Saved at the office under this name instead (shown until seen).
        var conflict: String?
        var seq: Int
        var version = 0
    }

    enum Op: Codable, Equatable {
        case remove(remote: String, base: Stamp?)
        case rename(from: String, to: String, base: Stamp?)
    }

    struct Saved: Codable {
        var office: String
        var share: String
        var shareName = ""
        var items: [String: Item] = [:]
        var ops: [Op] = []
        /// Per office folder: whether this Mac may write there (the last answer, for offline too).
        var access: [String: Bool] = [:]
        /// Whether the office takes writes at all (from driveInfo).
        var hostWrites = false
        var seq = 0
        /// Office actions that were refused (deletes, renames), to tell.
        var problems: [String] = []
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Edit Anywhere/Drive Writes", isDirectory: true)
    }

    let folder: URL
    private let lock = NSLock()
    private var saved: Saved
    private var touched: [String: Date] = [:]
    private var checked: [String: Date] = [:]
    private var settling = false
    /// How long a file is left alone before it goes (COMMIT sends sooner).
    nonisolated(unsafe) static var quiet: TimeInterval = 2

    /// Whether a path is one of the office's own (a proxy, the manifest or a folder of them): never written here.
    var known: @Sendable (String) -> Bool = { _ in false }
    /// Asks the office whether this Mac may write in a folder (nil: no answer).
    var askAccess: @Sendable (String) async -> Bool? = { _ in nil }
    /// A sent file's bytes from the office (its spool gone).
    var fetch: @Sendable (_ remote: String, _ offset: Int64, _ count: Int) async throws -> Data = { _, _, _ in throw RemoteDriveError.io }
    /// Something to send or show changed.
    var changed: @Sendable () -> Void = {}

    init(office: String, share: String) {
        let key = SHA256.hash(data: Data("\(office)|\(share)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        folder = Self.root.appendingPathComponent(key, isDirectory: true)
        saved = Saved(office: office, share: share)
        try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stateFile), var loaded = try? JSONDecoder().decode(Saved.self, from: data) {
            // The spool is the truth for sizes (a restart may come between a write and the next save).
            for (path, item) in loaded.items {
                guard let name = item.spool else { continue }
                if let size = (try? FileManager.default.attributesOfItem(atPath: spool.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value {
                    loaded.items[path]?.size = size
                } else {
                    loaded.items[path]?.spool = nil
                    if item.state == .pending, item.remote == nil { loaded.items[path] = nil }
                }
            }
            saved = loaded
        }
    }

    /// Every overlay saved on this Mac (pending ones go when their office answers).
    static func all() -> [RemoteDriveOverlay] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
            return RemoteDriveOverlay(office: saved.office, share: saved.share)
        }
    }

    var spool: URL { folder.appendingPathComponent("spool", isDirectory: true) }
    private var stateFile: URL { folder.appendingPathComponent("state.json") }
    var office: String { lock.withLock { saved.office } }
    var share: String { lock.withLock { saved.share } }
    var snapshot: Saved { lock.withLock { saved } }

    var hostWrites: Bool {
        get { lock.withLock { saved.hostWrites } }
        set { lock.withLock { saved.hostWrites = newValue }; save() }
    }

    var shareName: String {
        get { lock.withLock { saved.shareName } }
        set { lock.withLock { saved.shareName = newValue } }
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(saved) }
        try? data?.write(to: stateFile, options: .atomic)
    }

    // MARK: What stays here

    /// macOS's and Resolve's own files, hidden names and names the office can't take: kept on this Mac, never sent.
    static let localNames: Set<String> = [".DS_Store", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "CacheClip",
                                          ".gallery", "OptimizedMedia", "ProxyMedia"]
    static func keepsLocal(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in
            let name = String(part)
            return name.hasPrefix(".") || localNames.contains(name) || name.lowercased().hasSuffix(".lck") || !RemoteSendInto.nameOK(name)
        }
    }

    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    // MARK: The drive's view

    func node(_ path: String) -> RemoteDriveNode? {
        lock.withLock { saved.items[path].map { Self.node(path, $0) } }
    }

    private static func node(_ path: String, _ item: Item) -> RemoteDriveNode {
        RemoteDriveNode(name: (path as NSString).lastPathComponent, folder: item.folder, size: item.size, modified: item.modified, writable: true)
    }

    func children(_ path: String) -> [RemoteDriveNode] {
        lock.withLock {
            saved.items.filter { Self.parent($0.key) == path && $0.key != path }.map { Self.node($0.key, $0.value) }
        }
    }

    /// Whether this Mac may make files in a folder of the drive: the answer for the nearest folder the office has
    /// (cached; asked again in the background after two minutes; the last answer counts offline).
    func canWrite(_ folder: String) async -> Bool {
        let (office, ask): (String?, Bool) = lock.withLock {
            guard saved.hostWrites else { return (nil, false) }
            var probe = folder
            while true {
                if probe.isEmpty || known(probe) { break }
                if let item = saved.items[probe], item.state == .sent, let remote = item.remote { probe = remote; break }
                if saved.items[probe] == nil { return (nil, false) }
                probe = Self.parent(probe)
            }
            let stale = checked[probe].map { Date.now.timeIntervalSince($0) > 120 } ?? true
            if stale { checked[probe] = .now }
            return (probe, stale)
        }
        guard let office else { return false }
        let cached = lock.withLock { saved.access[office] }
        if ask {
            let query: @Sendable () async -> Void = { [self] in
                if let can = await askAccess(office) {
                    lock.withLock { saved.access[office] = can }
                    save()
                    changed()
                } else {
                    lock.withLock { checked[office] = nil }
                }
            }
            if cached == nil { await query() } else { Task { await query() } }
        }
        return lock.withLock { saved.access[office] } ?? false
    }

    /// Answers asked again from now on (the drive mounted again); `answers`: the kept ones count no more either (a role changed).
    func forgetAccess(answers: Bool = false) { lock.withLock { checked = [:]; if answers { saved.access = [:] } } }

    // MARK: Writing (the drive checks rights and the office's own paths first)

    func create(_ path: String, folder: Bool) throws -> RemoteDriveNode {
        let node = try lock.withLock { () -> RemoteDriveNode in
            guard saved.items[path] == nil else { throw RemoteDriveError.exists }
            if Self.parent(path) != "", let parent = saved.items[Self.parent(path)], !parent.folder { throw RemoteDriveError.notFolder }
            saved.seq += 1
            var item = Item(folder: folder, state: Self.keepsLocal(path) ? .local : .pending, seq: saved.seq)
            if !folder {
                let name = UUID().uuidString
                guard FileManager.default.createFile(atPath: spool.appendingPathComponent(name).path, contents: nil) else { throw RemoteDriveError.io }
                item.spool = name
                touched[path] = .now
            }
            saved.items[path] = item
            return Self.node(path, item)
        }
        save()
        settleLater()
        return node
    }

    /// The file's bytes on this Mac (a sent file's are fetched back first, unless it's being emptied anyway).
    private func ensureSpool(_ path: String, emptying: Bool) async throws -> URL {
        let (spoolName, remote, size) = try lock.withLock { () -> (String?, String?, Int64) in
            guard let item = saved.items[path] else { throw RemoteDriveError.noEntry }
            guard !item.folder else { throw RemoteDriveError.isFolder }
            return (item.spool, item.remote, item.size)
        }
        if let spoolName { return spool.appendingPathComponent(spoolName) }
        let name = UUID().uuidString, file = spool.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw RemoteDriveError.io }
        if !emptying, let remote {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var offset: Int64 = 0
            while offset < size {
                let piece = try await fetch(remote, offset, Int(min(Int64(OfficeLink.fileChunk), size - offset)))
                guard !piece.isEmpty else { throw RemoteDriveError.io }
                try handle.write(contentsOf: piece)
                offset += Int64(piece.count)
            }
        }
        lock.withLock { saved.items[path]?.spool = name }
        return file
    }

    func write(_ path: String, offset: Int64, data: Data) async throws -> RemoteDriveNode {
        let file = try await ensureSpool(path, emptying: false)
        let fd = open(file.path, O_WRONLY)
        guard fd >= 0 else { throw RemoteDriveError.io }
        defer { close(fd) }
        let written = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard written == data.count else { throw RemoteDriveError.io }
        return try touch(path) { $0.size = max($0.size, offset + Int64(data.count)) }
    }

    func change(_ path: String, size: Int64?, modified: Date?) async throws -> RemoteDriveNode {
        if lock.withLock({ saved.items[path]?.folder }) == true {
            return try touch(path, content: false) { if let modified { $0.modified = modified } }
        }
        if let size {
            let file = try await ensureSpool(path, emptying: size == 0)
            guard truncate(file.path, off_t(size)) == 0 else { throw RemoteDriveError.io }
        }
        return try touch(path, content: size != nil) { item in
            if let size { item.size = size }
            if let modified { item.modified = modified }
        }
    }

    /// A change to a file: it waits for the quiet period, then goes again.
    private func touch(_ path: String, content: Bool = true, _ edit: (inout Item) -> Void) throws -> RemoteDriveNode {
        let node = try lock.withLock { () -> RemoteDriveNode in
            guard var item = saved.items[path] else { throw RemoteDriveError.noEntry }
            edit(&item)
            if content {
                item.modified = .now
                item.version += 1
                if item.state != .local { item.state = .pending; item.note = nil }
                touched[path] = .now
            }
            saved.items[path] = item
            return Self.node(path, item)
        }
        settleLater()
        return node
    }

    func commit(_ path: String) {
        lock.withLock { _ = touched.removeValue(forKey: path) }
        save()
        changed()
    }

    private func settleLater() {
        guard lock.withLock({ () -> Bool in defer { settling = true }; return !settling }) else { return }
        Task.detached { [self] in
            while true {
                try? await Task.sleep(for: .seconds(Self.quiet))
                let left = lock.withLock { () -> Int in
                    touched = touched.filter { Date.now.timeIntervalSince($0.value) < Self.quiet }
                    if touched.isEmpty { settling = false }
                    return touched.count
                }
                save()
                changed()
                if left == 0 { return }
            }
        }
    }

    func remove(_ path: String) throws {
        try lock.withLock {
            guard let item = saved.items[path] else { throw RemoteDriveError.noEntry }
            if item.folder, saved.items.keys.contains(where: { Self.parent($0) == path }) { throw RemoteDriveError.notEmpty }
            if item.state != .local, let remote = item.remote { saved.ops.append(.remove(remote: remote, base: item.folder ? nil : item.base)) }
            if let name = item.spool { try? FileManager.default.removeItem(at: spool.appendingPathComponent(name)) }
            saved.items[path] = nil
            touched[path] = nil
        }
        save()
        changed()
    }

    /// A rename on the drive. Never sent yet: it simply goes under the new name (over the office file it replaces, as
    /// apps that save to a temporary name and rename do). Sent: the office renames it too.
    func rename(_ from: String, to: String) throws {
        try lock.withLock {
            guard var item = saved.items[from] else { throw RemoteDriveError.noEntry }
            let replaced = saved.items[to]
            if let replaced {
                guard replaced.folder == item.folder else { throw item.folder ? RemoteDriveError.notFolder : RemoteDriveError.isFolder }
                if replaced.folder, saved.items.keys.contains(where: { Self.parent($0) == to }) { throw RemoteDriveError.notEmpty }
            }
            let local = Self.keepsLocal(to)
            let officeTo = (saved.items[Self.parent(to)]?.remote ?? Self.parent(to)).isEmpty ? (to as NSString).lastPathComponent
                : (saved.items[Self.parent(to)]?.remote ?? Self.parent(to)) + "/" + (to as NSString).lastPathComponent
            let oldRemote = item.remote
            if let remote = item.remote, item.state != .local {
                if local {
                    saved.ops.append(.remove(remote: remote, base: item.folder ? nil : item.base))
                    item.remote = nil; item.base = nil; item.state = .local
                } else {
                    let target = replaced?.state != .local ? (replaced?.remote ?? officeTo) : officeTo
                    saved.ops.append(.rename(from: remote, to: target, base: replaced?.base))
                    item.remote = target
                }
            } else {
                item.state = local ? .local : .pending
                if !local, let replaced, replaced.state != .local, let remote = replaced.remote {
                    item.remote = remote; item.base = replaced.base
                } else { item.remote = nil; item.base = nil }
            }
            if let name = replaced?.spool { try? FileManager.default.removeItem(at: spool.appendingPathComponent(name)) }
            saved.items[from] = nil
            saved.items[to] = item
            touched[to] = touched.removeValue(forKey: from)
            // A folder's own files and folders move with it (their office paths too).
            if item.folder {
                for key in saved.items.keys where key.hasPrefix(from + "/") {
                    guard var child = saved.items.removeValue(forKey: key) else { continue }
                    if let old = oldRemote, let new = item.remote, let remote = child.remote, remote.hasPrefix(old + "/") {
                        child.remote = new + remote.dropFirst(old.count)
                    }
                    if item.state == .local { child.state = .local }
                    saved.items[to + key.dropFirst(from.count)] = child
                }
            }
        }
        save()
        changed()
    }

    func read(_ path: String, offset: Int64, count: Int) async throws -> Data {
        let (name, remote, size) = try lock.withLock { () -> (String?, String?, Int64) in
            guard let item = saved.items[path], !item.folder else { throw RemoteDriveError.noEntry }
            return (item.spool, item.remote, item.size)
        }
        guard offset < size, count > 0 else { return Data() }
        if let name {
            let handle = try FileHandle(forReadingFrom: spool.appendingPathComponent(name))
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        guard let remote else { throw RemoteDriveError.io }
        return try await fetch(remote, offset, Int(min(Int64(count), size - offset)))
    }

    /// At Disconnect: sent files' copies here go (read back from the office if opened again).
    func dropSentSpools() {
        lock.withLock {
            for (path, item) in saved.items where item.state == .sent && !item.folder {
                if let name = item.spool { try? FileManager.default.removeItem(at: spool.appendingPathComponent(name)) }
                saved.items[path]?.spool = nil
            }
        }
        save()
    }

    // MARK: For the uploads and the window

    var hasWork: Bool { lock.withLock { !saved.ops.isEmpty || saved.items.values.contains { $0.state == .pending } } }

    func seen(_ path: String) {
        lock.withLock { saved.items[path]?.conflict = nil }
        save(); changed()
    }

    func retry(_ path: String) {
        lock.withLock {
            guard saved.items[path]?.state == .refused else { return }
            saved.items[path]?.state = .pending
            saved.items[path]?.note = nil
        }
        save(); changed()
    }

    func clearProblems() { lock.withLock { saved.problems = [] }; save(); changed() }

    fileprivate func nextOp() -> Op? { lock.withLock { saved.ops.first } }

    fileprivate func opDone(_ op: Op, problem: String? = nil, renamed: String? = nil) {
        lock.withLock {
            guard saved.ops.first == op else { return }
            saved.ops.removeFirst()
            if let problem { saved.problems.append(problem) }
            // The office gave the renamed file another name (its own was there): this Mac follows.
            if case .rename(_, let to, _) = op, let renamed, renamed != (to as NSString).lastPathComponent {
                let now = (Self.parent(to).isEmpty ? "" : Self.parent(to) + "/") + renamed
                for (path, item) in saved.items where item.remote == to {
                    saved.items[path]?.remote = now
                    saved.items[path]?.conflict = renamed
                }
            }
        }
        save(); changed()
    }

    /// The next item to send: shallow ones first (a folder before what's in it), oldest first; none still being written.
    fileprivate func nextItem() -> (path: String, item: Item)? {
        lock.withLock {
            saved.items.filter { $0.value.state == .pending && touched[$0.key] == nil }
                .min { ($0.key.split(separator: "/").count, $0.value.seq) < ($1.key.split(separator: "/").count, $1.value.seq) }
                .map { ($0.key, $0.value) }
        }
    }

    /// Where an item goes at the office: its own office path, else its folder's and its name.
    fileprivate func officePath(_ path: String) -> String {
        lock.withLock {
            if let remote = saved.items[path]?.remote { return remote }
            let parent = Self.parent(path), name = (path as NSString).lastPathComponent
            let folder = saved.items[parent]?.remote ?? parent
            return folder.isEmpty ? name : folder + "/" + name
        }
    }

    /// A folder made or a file placed at the office (`version`: the one sent; changed since, it goes again).
    fileprivate func sent(spool: String?, path: String, version: Int, remote: String, base: Stamp?, conflict: Bool) {
        lock.withLock {
            let found = spool.flatMap { name in saved.items.first { $0.value.spool == name }?.key } ?? (saved.items[path] != nil ? path : nil)
            guard let key = found, var item = saved.items[key] else {
                // Deleted here meanwhile: it goes from the office too.
                saved.ops.append(.remove(remote: remote, base: base))
                return
            }
            item.remote = remote
            item.base = base
            if conflict { item.conflict = (remote as NSString).lastPathComponent }
            if item.state == .pending, item.version == version { item.state = .sent }
            saved.items[key] = item
        }
        save(); changed()
    }

    fileprivate func refused(_ path: String, _ message: String) {
        lock.withLock {
            saved.items[path]?.state = .refused
            saved.items[path]?.note = message
        }
        save(); changed()
    }
}

// MARK: - The drive's writes (the office's proxies never; elsewhere where this Mac may)

extension RemoteShareDrive {
    var writes: Bool { overlay?.hostWrites == true }

    private func writableOverlay(_ folder: String, for path: String) async throws -> RemoteDriveOverlay {
        guard let overlay, overlay.hostWrites else { throw RemoteDriveError.readOnly }
        if RemoteDriveOverlay.keepsLocal(path) { return overlay }
        guard await overlay.canWrite(folder) else { throw RemoteDriveError.denied }
        return overlay
    }

    /// The overlay's item at `path` (the office's own paths: refused).
    private func own(_ path: String) throws -> RemoteDriveOverlay {
        guard let overlay, overlay.hostWrites else { throw RemoteDriveError.readOnly }
        if current.nodes[path] != nil { throw RemoteDriveError.denied }
        guard overlay.node(path) != nil else { throw RemoteDriveError.noEntry }
        return overlay
    }

    func create(_ path: String, folder: Bool) async throws -> RemoteDriveNode {
        if current.nodes[path] != nil { throw RemoteDriveError.exists }
        return try await writableOverlay(RemoteDriveOverlay.parent(path), for: path).create(path, folder: folder)
    }

    func write(_ path: String, offset: Int64, data: Data) async throws -> RemoteDriveNode {
        try await own(path).write(path, offset: offset, data: data)
    }

    func change(_ path: String, size: Int64?, modified: Date?) async throws -> RemoteDriveNode {
        try await own(path).change(path, size: size, modified: modified)
    }

    func remove(_ path: String, folder: Bool) async throws {
        try own(path).remove(path)
    }

    func rename(_ from: String, to: String) async throws {
        let overlay = try own(from)
        if current.nodes[to] != nil { throw RemoteDriveError.denied }
        // A name that goes to the office needs the right there (a move into a hidden or cache name stays here).
        _ = try await writableOverlay(RemoteDriveOverlay.parent(to), for: to)
        try overlay.rename(from, to: to)
    }

    func commit(_ path: String) async { overlay?.commit(path) }
}

// MARK: - Sending to the office

/// Every share's overlay on this Mac, sending what waits whenever its office answers; what the window shows.
@MainActor
@Observable
final class RemoteDriveWrites {
    static let shared = RemoteDriveWrites()

    struct Summary: Equatable {
        var pending = 0
        var pendingBytes: Int64 = 0
        var sending: String?
        var conflicts: [(path: String, name: String)] = []
        var refused: [(path: String, message: String)] = []
        var problems: [String] = []
        static func == (a: Summary, b: Summary) -> Bool {
            a.pending == b.pending && a.pendingBytes == b.pendingBytes && a.sending == b.sending && a.problems == b.problems
                && a.conflicts.map(\.path) == b.conflicts.map(\.path) && a.refused.map(\.path) == b.refused.map(\.path)
        }
    }

    private(set) var summaries: [String: Summary] = [:]
    @ObservationIgnored private var overlays: [String: RemoteDriveOverlay] = [:]
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var again = false
    @ObservationIgnored private var nap: Task<Void, Never>?
    @ObservationIgnored private var sending: [String: String] = [:]

    private init() {}

    /// At launch: overlays with something waiting are picked up (sent once their office answers).
    func install() {
        for overlay in RemoteDriveOverlay.all() where overlays[overlay.share] == nil { adopt(overlay) }
        kick()
    }

    /// The overlay of a share of this office (made or loaded).
    func overlay(office: String, share: String) -> RemoteDriveOverlay {
        if let have = overlays[share], have.office == office { return have }
        let overlay = RemoteDriveOverlay(office: office, share: share)
        adopt(overlay)
        return overlay
    }

    private func adopt(_ overlay: RemoteDriveOverlay) {
        overlays[overlay.share] = overlay
        let share = overlay.share
        overlay.askAccess = { folder in
            (try? await OfficeRenderClient.shared.ask("driveCanWrite", ["share": share, "path": folder], timeout: 20))?["can"] as? Bool
        }
        overlay.fetch = { remote, offset, count in
            try await OfficeRenderClient.shared.fileData(share: share, path: remote, kind: .original, offset: offset, length: count).data
        }
        overlay.changed = { Task { @MainActor in RemoteDriveWrites.shared.refreshed(share); RemoteDriveWrites.shared.kick() } }
        refreshed(share)
    }

    func summary(_ share: String) -> Summary { summaries[share] ?? Summary() }

    func refreshed(_ share: String) {
        guard let overlay = overlays[share] else { return }
        let saved = overlay.snapshot
        var summary = Summary()
        let waiting = saved.items.filter { $0.value.state == .pending && !$0.value.folder }
        summary.pending = waiting.count + saved.ops.count
        summary.pendingBytes = waiting.values.reduce(0) { $0 + $1.size }
        summary.sending = sending[share]
        summary.conflicts = saved.items.compactMap { path, item in item.conflict.map { (path, $0) } }.sorted { $0.path < $1.path }
        summary.refused = saved.items.compactMap { path, item in item.state == .refused ? (path, item.note ?? "") : nil }.sorted { $0.path < $1.path }
        summary.problems = saved.problems
        if summaries[share] != summary { summaries[share] = summary }
    }

    func seen(_ share: String, _ path: String) { overlays[share]?.seen(path) }
    func retry(_ share: String, _ path: String) { overlays[share]?.retry(path) }
    func clearProblems(_ share: String) { overlays[share]?.clearProblems() }

    /// Sends what waits (one pass at a time; asked again meanwhile, another pass follows). An office out of reach: again
    /// in 30 s, or sooner when something new is written. (A file still being written is sent when it settles: that asks again.)
    func kick() {
        guard running == nil else { again = true; nap?.cancel(); return }
        running = Task {
            repeat {
                again = false
                var unreachable = false
                for overlay in overlays.values where overlay.hasWork {
                    guard OfficeRenderClient.shared.office?.device.uuidString == overlay.office else { continue }
                    if await !Self.pass(overlay) { unreachable = true }
                    refreshed(overlay.share)
                }
                if unreachable, !again {
                    let nap = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
                    self.nap = nap
                    await nap.value
                    self.nap = nil
                    again = true
                }
            } while again && !Task.isCancelled
            running = nil
        }
    }

    /// Waits until nothing is being sent (tests).
    func settled() async { while let running { await running.value } }

    /// One pass over an overlay: the office's deletes and renames first, then folders and files. False: the office
    /// didn't answer (all stays queued).
    static func pass(_ overlay: RemoteDriveOverlay, client: OfficeRenderClient? = nil) async -> Bool {
        let client = client ?? .shared, share = overlay.share
        func base(_ stamp: RemoteDriveOverlay.Stamp?) -> [String: Any] {
            stamp.map { ["baseSize": $0.size, "baseModified": $0.modified] } ?? [:]
        }
        while let op = overlay.nextOp() {
            do {
                switch op {
                case .remove(let remote, let stamp):
                    let answer = try await client.ask("driveRemove", ["share": share, "path": remote].merging(base(stamp)) { a, _ in a })
                    overlay.opDone(op, problem: answer["trashed"] as? Bool == false
                                   ? String(localized: "“\((remote as NSString).lastPathComponent)” changed at the office, so it wasn’t deleted there.") : nil)
                case .rename(let from, let to, let stamp):
                    let answer = try await client.ask("driveRename", ["share": share, "path": from, "to": to].merging(base(stamp)) { a, _ in a })
                    overlay.opDone(op, renamed: answer["name"] as? String)
                }
            } catch OfficeLink.Failure.office(let message) {
                overlay.opDone(op, problem: message)
            } catch {
                return false
            }
        }
        while let (path, item) = overlay.nextItem() {
            let remote = overlay.officePath(path)
            RemoteDriveWrites.shared.sending[share] = (path as NSString).lastPathComponent
            defer { RemoteDriveWrites.shared.sending[share] = nil }
            do {
                if item.folder {
                    _ = try await client.ask("driveFolder", ["share": share, "path": remote])
                    overlay.sent(spool: nil, path: path, version: item.version, remote: remote, base: nil, conflict: false)
                } else {
                    try await send(overlay, path: path, item: item, remote: remote, client: client, base: base(item.base))
                }
            } catch OfficeLink.Failure.office(let message) {
                overlay.refused(path, message)
            } catch {
                return false
            }
        }
        return true
    }

    /// One file: a copy of its spool as it is now (later writes go with the next pass), resumed, checked, placed.
    private static func send(_ overlay: RemoteDriveOverlay, path: String, item: RemoteDriveOverlay.Item, remote: String,
                             client: OfficeRenderClient, base: [String: Any]) async throws {
        guard let spoolName = item.spool else { return overlay.refused(path, String(localized: "This file’s copy on this Mac is gone.")) }
        let copy = overlay.folder.appendingPathComponent("sending-" + spoolName)
        try? FileManager.default.removeItem(at: copy)
        guard copyfile(overlay.spool.appendingPathComponent(spoolName).path, copy.path, nil, copyfile_flags_t(COPYFILE_CLONE)) == 0 else {
            throw RemoteDriveError.io
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        let size = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try await Task.detached { try RemoteSendInto.hash(copy) }.value
        let modified = item.modified.timeIntervalSince1970.rounded()
        let file: [String: Any] = ["share": overlay.share, "path": remote, "size": size, "modified": modified]
        var have = (try await client.ask("driveWriteState", file)["have"] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: copy)
        defer { try? handle.close() }
        while true {
            try handle.seek(toOffset: UInt64(have))
            let chunk = try handle.read(upToCount: OfficeLink.uploadChunk) ?? Data()
            var piece = file.merging(base) { a, _ in a }
            piece["offset"] = have
            piece["data"] = chunk.base64EncodedString()
            if have + Int64(chunk.count) == size { piece["sha256"] = sha }
            let answer = try await client.ask("driveWrite", piece, timeout: 120)
            have = (answer["have"] as? NSNumber)?.int64Value ?? have
            if let name = answer["name"] as? String {
                let folder = RemoteDriveOverlay.parent(remote)
                let stamp = RemoteDriveOverlay.Stamp(size: (answer["size"] as? NSNumber)?.int64Value ?? size,
                                                     modified: (answer["modified"] as? NSNumber)?.doubleValue ?? modified)
                overlay.sent(spool: spoolName, path: path, version: item.version, remote: folder.isEmpty ? name : folder + "/" + name,
                             base: stamp, conflict: answer["conflict"] as? Bool == true)
                return
            }
            if chunk.isEmpty { throw RemoteDriveError.io }
        }
    }
}
