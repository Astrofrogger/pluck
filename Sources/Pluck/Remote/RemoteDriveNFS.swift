import CryptoKit
import Foundation
import Network

/// Pluck's own drive: a tiny NFSv3 server (RFC 1813, ONC RPC RFC 5531, XDR RFC 4506) on
/// 127.0.0.1, so a share streamed from the host mounts with plain `mount_nfs` (no File Sharing, no admin,
/// no extra install). It knows nothing about the host: a `RemoteDriveBackend` answers for paths.
/// Paths are share-proxy relative, "" for the top, "a/b.mov" below it.
/// Read-only unless the backend `writes` (RemoteDriveWrite: CREATE, WRITE, COMMIT, SETATTR, REMOVE, RENAME, MKDIR, RMDIR
/// land in a local overlay and go to the office from there); a read-only drive answers every write with EROFS.

struct RemoteDriveNode: Sendable, Equatable {
    var name: String
    var folder: Bool
    var size: Int64
    var modified: Date
    /// Changes are taken here (a folder: new files in it; a file: its bytes, rename, remove).
    var writable = false
}

enum RemoteDriveError: Error { case noEntry, io, notFolder, readOnly, denied, exists, notEmpty, isFolder, busy, invalid }

protocol RemoteDriveBackend: AnyObject, Sendable {
    func node(_ path: String) async throws -> RemoteDriveNode
    func list(_ path: String) async throws -> [RemoteDriveNode]
    func read(_ path: String, offset: Int64, count: Int) async throws -> Data
    /// Whether the drive takes writes at all (false: mounted read-only, every write is EROFS).
    var writes: Bool { get }
    func create(_ path: String, folder: Bool) async throws -> RemoteDriveNode
    func write(_ path: String, offset: Int64, data: Data) async throws -> RemoteDriveNode
    /// A new size (truncate or extend) and/or modification date.
    func change(_ path: String, size: Int64?, modified: Date?) async throws -> RemoteDriveNode
    func remove(_ path: String, folder: Bool) async throws
    func rename(_ from: String, to: String) async throws
    /// The client says the file is complete for now (COMMIT): it may go to the office.
    func commit(_ path: String) async
}

extension RemoteDriveBackend {
    var writes: Bool { false }
    func create(_ path: String, folder: Bool) async throws -> RemoteDriveNode { throw RemoteDriveError.readOnly }
    func write(_ path: String, offset: Int64, data: Data) async throws -> RemoteDriveNode { throw RemoteDriveError.readOnly }
    func change(_ path: String, size: Int64?, modified: Date?) async throws -> RemoteDriveNode { throw RemoteDriveError.readOnly }
    func remove(_ path: String, folder: Bool) async throws { throw RemoteDriveError.readOnly }
    func rename(_ from: String, to: String) async throws { throw RemoteDriveError.readOnly }
    func commit(_ path: String) async {}
}

// MARK: - XDR

struct XDRWriter {
    var data = Data()
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bool(_ value: Bool) { u32(value ? 1 : 0) }
    mutating func fixed(_ bytes: Data) {
        data.append(bytes)
        let pad = (4 - bytes.count % 4) % 4
        if pad > 0 { data.append(Data(count: pad)) }
    }
    mutating func opaque(_ bytes: Data) { u32(UInt32(bytes.count)); fixed(bytes) }
    mutating func string(_ text: String) { opaque(Data(text.utf8)) }
}

struct XDRReader {
    let data: Data
    var at: Int
    init(_ data: Data) { self.data = data; at = data.startIndex }
    struct Short: Error {}

    mutating func u32() throws -> UInt32 {
        guard at + 4 <= data.endIndex else { throw Short() }
        defer { at += 4 }
        return data[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
    mutating func fixed(_ count: Int) throws -> Data {
        let padded = count + (4 - count % 4) % 4
        guard count >= 0, at + padded <= data.endIndex else { throw Short() }
        defer { at += padded }
        return Data(data[at..<at + count])
    }
    mutating func opaque(max: Int) throws -> Data {
        let count = Int(try u32())
        guard count <= max else { throw Short() }
        return try fixed(count)
    }
    mutating func string(max: Int = 1024) throws -> String {
        guard let text = String(data: try opaque(max: max), encoding: .utf8) else { throw Short() }
        return text
    }
}

// MARK: - The server

final class RemoteDriveServer: @unchecked Sendable {
    static let nfsProgram: UInt32 = 100003, mountProgram: UInt32 = 100005
    /// NFSv3 status codes used here.
    enum Status: UInt32 {
        case ok = 0, noent = 2, io = 5, acces = 13, exist = 17, notdir = 20, isdir = 21, inval = 22, rofs = 30, notempty = 66
        case stale = 70, badhandle = 10001, badCookie = 10003, notsupp = 10004, serverfault = 10006, jukebox = 10008
    }

    let backend: RemoteDriveBackend
    /// The export name mount_nfs asks for: "/pluck-<random>" per run, given only to mount_nfs (never listed).
    let export: String
    private let queue = DispatchQueue(label: "pluck.drive")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var paths: [Data: String] = [:]
    /// The handle each path has now (a path made again after a rename or delete gets a new one).
    private var handles: [String: Data] = [:]
    /// Where the handle of a deleted or replaced file points: nowhere (STALE).
    private static let gone = "\0gone"
    private(set) var port: UInt16 = 0
    /// Any process on this Mac can reach 127.0.0.1, so the root handle is only given out while Pluck itself
    /// mounts, and handles are salted per run (no guessing one from a path).
    private static let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var mounting = false
    /// WRITE and COMMIT verifier: new per run, so a client resends what an earlier run never kept.
    private static let verifier = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
    func allowMount(_ open: Bool) { lock.lock(); mounting = open; lock.unlock() }

    init(backend: RemoteDriveBackend, export: String = "/pluck-" + UUID().uuidString.prefix(13).lowercased()) {
        self.backend = backend
        self.export = export
        _ = handle("")
    }

    /// Listens on 127.0.0.1 only, on a free port; returns it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { if once.claim() { continuation.resume(with: $0) } }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.port = port
                    finish(.success(port))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock(); let open = connections.values; connections = [:]; lock.unlock()
        open.forEach { $0.cancel() }
    }

    // MARK: File handles: stable per path (hash), mapped back while the server runs

    func handle(_ path: String) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let known = handles[path] { return known }
        // (Taken by another file, one renamed away or deleted: a new generation, so the old handle never aliases this one.)
        var generation = 0, value = Data()
        repeat {
            value = Data(SHA256.hash(data: Self.salt + Data(path.utf8) + (generation == 0 ? Data() : Data("\0\(generation)".utf8))).prefix(16))
            generation += 1
        } while paths[value] != nil
        paths[value] = path
        handles[path] = value
        return value
    }

    func path(_ handle: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        return paths[handle].flatMap { $0 == Self.gone ? nil : $0 }
    }

    /// After a rename: the handles a client still holds for the old path (and what's in it) find them at the new one;
    /// a file it replaced goes stale.
    func moved(_ from: String, to: String) {
        guard from != to else { return }
        lock.lock(); defer { lock.unlock() }
        forget(to)
        for (path, value) in handles where path == from || path.hasPrefix(from + "/") {
            let now = to + path.dropFirst(from.count)
            handles[path] = nil
            handles[now] = value
            paths[value] = now
        }
    }

    /// After a delete: its handles (and those of what was in it) go stale.
    func removed(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        forget(path)
    }

    private func forget(_ path: String) {
        for (known, value) in handles where known == path || known.hasPrefix(path + "/") {
            handles[known] = nil
            paths[value] = Self.gone
        }
    }

    static func fileID(_ handle: Data) -> UInt64 { handle.prefix(8).reduce(0) { $0 << 8 | UInt64($1) } | 1 }

    // MARK: Connections and record marking

    private func accept(_ connection: NWConnection) {
        // Only this Mac: the listener is bound to 127.0.0.1, and the peer must be too.
        if case .hostPort(let host, _) = connection.endpoint, "\(host)" != "127.0.0.1" {
            connection.cancel()
            return
        }
        let key = ObjectIdentifier(connection)
        lock.lock(); connections[key] = connection; lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.lock.lock(); self?.connections[key] = nil; self?.lock.unlock()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data(), record: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data, record: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, complete, error in
            guard let self else { return }
            var buffer = buffer + (content ?? Data()), record = record
            while buffer.count >= 4 {
                let header = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                let length = Int(header & 0x7fff_ffff)
                guard length <= 2 << 20, record.count + length <= 2 << 20 else { connection.cancel(); return }
                guard buffer.count >= 4 + length else { break }
                record += buffer.dropFirst(4).prefix(length)
                buffer = Data(buffer.dropFirst(4 + length))
                if header & 0x8000_0000 != 0 {
                    let call = record
                    record = Data()
                    Task { [weak self] in
                        guard let self, let reply = await self.reply(to: call) else { return }
                        var framed = XDRWriter()
                        framed.u32(0x8000_0000 | UInt32(reply.count))
                        framed.data.append(reply)
                        connection.send(content: framed.data, completion: .contentProcessed { _ in })
                    }
                }
            }
            if complete || error != nil { connection.cancel(); return }
            self.receive(connection, buffer: buffer, record: record)
        }
    }

    // MARK: RPC

    /// The reply record for one call record (nil: not a call, dropped).
    func reply(to call: Data) async -> Data? {
        var input = XDRReader(call)
        guard let xid = try? input.u32(), (try? input.u32()) == 0 else { return nil }
        var out = XDRWriter()
        out.u32(xid); out.u32(1) // REPLY
        guard let rpcVersion = try? input.u32(), let program = try? input.u32(), let version = try? input.u32(),
              let procedure = try? input.u32(), let flavor = try? input.u32(), let credential = try? input.opaque(max: 400),
              (try? input.u32()) != nil, (try? input.opaque(max: 400)) != nil else { return nil }
        guard rpcVersion == 2 else {
            out.u32(1); out.u32(0); out.u32(2); out.u32(2) // MSG_DENIED, RPC_MISMATCH 2...2
            return out.data
        }
        // AUTH_SYS from this user (or root, the kernel's own) only; AUTH_NONE just for NULL pings.
        guard flavor == 1 ? Self.isOwner(credential) : flavor == 0 && procedure == 0 else {
            out.u32(1); out.u32(1); out.u32(flavor == 0 ? 5 : 1) // MSG_DENIED, AUTH_ERROR, AUTH_TOOWEAK / AUTH_BADCRED
            return out.data
        }
        out.u32(0); out.u32(0); out.u32(0) // MSG_ACCEPTED, verifier AUTH_NONE, empty
        let known = program == Self.nfsProgram || program == Self.mountProgram
        guard known else { out.u32(1); return out.data } // PROG_UNAVAIL
        guard version == 3 else { out.u32(2); out.u32(3); out.u32(3); return out.data } // PROG_MISMATCH 3...3
        var body = XDRWriter()
        do {
            let handled = program == Self.mountProgram
                ? try mount(procedure, &input, &body)
                : try await nfs(procedure, &input, &body)
            guard handled else { out.u32(3); return out.data } // PROC_UNAVAIL
        } catch {
            out.u32(4); return out.data // GARBAGE_ARGS
        }
        out.u32(0) // SUCCESS
        out.data.append(body.data)
        return out.data
    }

    /// An AUTH_SYS credential (stamp, machine name, uid, gid, gids) naming this user or root.
    /// shortcut: AUTH_SYS is self-declared, so a local process can still claim the uid; the random export name and the
    /// mount window are the real gates. Upgrade: tie the TCP peer to its process (or use a Unix socket) if that matters.
    static func isOwner(_ credential: Data) -> Bool {
        var reader = XDRReader(credential)
        guard (try? reader.u32()) != nil, (try? reader.string(max: 255)) != nil, let uid = try? reader.u32() else { return false }
        return uid == getuid() || uid == 0
    }

    // MARK: MOUNT v3

    private func mount(_ procedure: UInt32, _ input: inout XDRReader, _ out: inout XDRWriter) throws -> Bool {
        switch procedure {
        case 0: break // NULL
        case 1: // MNT
            let dir = try input.string()
            lock.lock(); let open = mounting; lock.unlock()
            if !open {
                out.u32(13) // MNT3ERR_ACCES
            } else if dir == export || dir == export + "/" {
                out.u32(0)
                out.opaque(handle(""))
                out.u32(2); out.u32(0); out.u32(1) // auth flavors: AUTH_NONE, AUTH_SYS
            } else {
                out.u32(2) // MNT3ERR_NOENT
            }
        case 2: out.bool(false) // DUMP: no list
        case 3: _ = try input.string() // UMNT
        case 4: break // UMNTALL
        case 5: // EXPORT: no list either (the export name is what keeps other processes out)
            out.bool(false)
        default: return false
        }
        return true
    }

    // MARK: NFS v3

    private func fattr(_ node: RemoteDriveNode, handle: Data, _ out: inout XDRWriter) {
        out.u32(node.folder ? 2 : 1)
        out.u32(node.folder ? (node.writable ? 0o755 : 0o555) : (node.writable ? 0o644 : 0o444))
        out.u32(node.folder ? 2 : 1)
        out.u32(getuid()); out.u32(getgid())
        let size = UInt64(max(0, node.size))
        out.u64(size); out.u64(size)
        out.u32(0); out.u32(0) // rdev
        out.u64(0x504c_434b) // fsid
        out.u64(Self.fileID(handle))
        let seconds = UInt32(clamping: Int64(max(0, node.modified.timeIntervalSince1970)))
        for _ in 0..<3 { out.u32(seconds); out.u32(0) }
    }

    private func postAttr(_ node: RemoteDriveNode?, handle: Data, _ out: inout XDRWriter) {
        out.bool(node != nil)
        if let node { fattr(node, handle: handle, &out) }
    }

    private func status(of error: Error) -> Status {
        switch error as? RemoteDriveError {
        case .noEntry: .noent
        case .notFolder: .notdir
        case .readOnly: .rofs
        case .denied: .acces
        case .exists: .exist
        case .notEmpty: .notempty
        case .isFolder: .isdir
        case .busy: .jukebox
        case .invalid: .inval
        default: .io
        }
    }

    /// wcc_data: no "before" attributes (allowed), the attributes after.
    private func wcc(_ node: RemoteDriveNode?, handle: Data, _ out: inout XDRWriter) {
        out.bool(false); postAttr(node, handle: handle, &out)
    }

    /// sattr3: the size and modification date asked for (mode, owner and access time are taken and ignored).
    private func sattr(_ input: inout XDRReader) throws -> (size: Int64?, modified: Date?) {
        if try input.u32() != 0 { _ = try input.u32() } // mode
        if try input.u32() != 0 { _ = try input.u32() } // uid
        if try input.u32() != 0 { _ = try input.u32() } // gid
        let size: Int64? = try input.u32() != 0 ? Int64(clamping: try input.u64()) : nil
        func time() throws -> Date? {
            switch try input.u32() {
            case 1: return .now // SET_TO_SERVER_TIME
            case 2: let seconds = try input.u32(), nanos = try input.u32(); return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9)
            default: return nil
            }
        }
        _ = try time()
        return (size, try time())
    }

    /// A child's path from a name the client sent (nil: not a plain name).
    private static func child(_ folder: String, _ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return folder.isEmpty ? name : folder + "/" + name
    }

    /// How many empty words a procedure's failure body has: post_op_attr (1), wcc_data (2), LINK (3), RENAME (4).
    private static func failureWords(_ procedure: UInt32) -> Int {
        switch procedure {
        case 1: 0
        case 2, 7, 8, 9, 10, 11, 12, 13, 21: 2
        case 15: 3
        case 14: 4
        default: 1
        }
    }

    private func nfs(_ procedure: UInt32, _ input: inout XDRReader, _ out: inout XDRWriter) async throws -> Bool {
        if procedure == 0 { return true }
        // Writing procedures on a read-only drive (and links, symlinks and devices on any): refused, with their empty "failure" bodies.
        let writing: Set<UInt32> = [2, 7, 8, 9, 12, 13, 14, 21]
        if [10, 11, 15].contains(procedure) || (writing.contains(procedure) && !backend.writes) {
            out.u32((backend.writes ? Status.notsupp : Status.rofs).rawValue)
            for _ in 0..<Self.failureWords(procedure) { out.u32(0) }
            return true
        }
        guard procedure <= 21 else { return false }
        let handle = try input.opaque(max: 64)
        func fail(_ status: Status) { out.u32(status.rawValue); for _ in 0..<Self.failureWords(procedure) { out.u32(0) } }
        guard let path = path(handle) else { fail(.stale); return true }
        let node: RemoteDriveNode
        // (A handle given out for a path that's gone: STALE, so the client looks the name up again. Never the root's: a stale
        // root would leave the mount stuck while the share's tree is loaded again.)
        do { node = try await backend.node(path) } catch { fail(error as? RemoteDriveError == .noEntry && !path.isEmpty ? .stale : status(of: error)); return true }
        if writing.contains(procedure) {
            try await nfsWrite(procedure, path: path, node: node, handle: handle, &input, &out)
            return true
        }
        switch procedure {
        case 1: // GETATTR
            out.u32(0); fattr(node, handle: handle, &out)
        case 3: // LOOKUP
            let name = try input.string(max: 255)
            guard node.folder else { out.u32(Status.notdir.rawValue); postAttr(node, handle: handle, &out); break }
            let childPath: String
            if name == "." { childPath = path }
            else if name == ".." { childPath = (path as NSString).deletingLastPathComponent }
            else if name.isEmpty || name.contains("/") || name.contains("\0") {
                out.u32(Status.noent.rawValue); postAttr(node, handle: handle, &out); break
            } else { childPath = path.isEmpty ? name : path + "/" + name }
            do {
                let child = try await backend.node(childPath)
                let childHandle = self.handle(childPath)
                out.u32(0); out.opaque(childHandle)
                postAttr(child, handle: childHandle, &out)
                postAttr(node, handle: handle, &out)
            } catch {
                out.u32(status(of: error).rawValue); postAttr(node, handle: handle, &out)
            }
        case 4: // ACCESS: read, lookup, execute; modify, extend (and delete in a folder) where it's writable
            let asked = try input.u32()
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(asked & (node.folder ? (node.writable ? 0x3f : 0x23) : (node.writable ? 0x2d : 0x21)))
        case 5: // READLINK: no links here
            out.u32(Status.inval.rawValue); postAttr(node, handle: handle, &out)
        case 6: // READ
            let offset = try input.u64(), count = Int(min(try input.u32(), 1 << 20))
            guard !node.folder else { out.u32(Status.isdir.rawValue); postAttr(node, handle: handle, &out); break }
            let size = UInt64(max(0, node.size))
            var bytes = Data()
            if offset < size, count > 0 {
                do { bytes = try await backend.read(path, offset: Int64(offset), count: Int(min(UInt64(count), size - offset))) } catch {
                    out.u32(status(of: error).rawValue); postAttr(node, handle: handle, &out); break
                }
            }
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(UInt32(bytes.count)); out.bool(offset + UInt64(bytes.count) >= size); out.opaque(bytes)
        case 16, 17: // READDIR, READDIRPLUS
            let cookie = try input.u64(); _ = try input.fixed(8)
            let plus = procedure == 17
            if plus { _ = try input.u32() }
            let maxBytes = Int(try input.u32())
            guard node.folder else { out.u32(Status.notdir.rawValue); postAttr(node, handle: handle, &out); break }
            let children: [RemoteDriveNode]
            do { children = try await backend.list(path) } catch {
                out.u32(status(of: error).rawValue); postAttr(node, handle: handle, &out); break
            }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = path.isEmpty ? node : ((try? await backend.node(parentPath)) ?? node)
            var all: [(String, String, RemoteDriveNode)] = [(".", path, node), ("..", path.isEmpty ? path : parentPath, parent)]
            all += children.map { ($0.name, path.isEmpty ? $0.name : path + "/" + $0.name, $0) }
            guard cookie <= UInt64(all.count) else { out.u32(Status.badCookie.rawValue); postAttr(node, handle: handle, &out); break }
            var head = XDRWriter()
            head.u32(0); postAttr(node, handle: handle, &head); head.fixed(Data(count: 8))
            var entries = XDRWriter(), index = Int(cookie), budget = max(512, maxBytes) - head.data.count - 16
            while index < all.count {
                let (name, childPath, child) = all[index]
                var entry = XDRWriter()
                let childHandle = self.handle(childPath)
                entry.bool(true); entry.u64(Self.fileID(childHandle)); entry.string(name); entry.u64(UInt64(index + 1))
                if plus {
                    postAttr(child, handle: childHandle, &entry)
                    entry.bool(true); entry.opaque(childHandle)
                }
                guard entry.data.count <= budget else { break }
                budget -= entry.data.count
                entries.data.append(entry.data)
                index += 1
            }
            if index == Int(cookie), index < all.count { out.u32(10005); postAttr(node, handle: handle, &out); break } // TOOSMALL
            out.data.append(head.data); out.data.append(entries.data)
            out.bool(false); out.bool(index >= all.count)
        case 18: // FSSTAT
            out.u32(0); postAttr(node, handle: handle, &out)
            // shortcut: a writable drive says 512 GB free (Finder refuses a copy onto 0); the office checks its real room on upload.
            let free: UInt64 = backend.writes ? 1 << 39 : 0
            out.u64(1 << 40); out.u64(free); out.u64(free); out.u64(1 << 20); out.u64(0); out.u64(0); out.u32(1)
        case 19: // FSINFO
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(1 << 20); out.u32(1 << 20); out.u32(4096) // read max, preferred, multiple
            out.u32(1 << 20); out.u32(1 << 20); out.u32(4096) // write max, preferred, multiple
            out.u32(64 << 10) // readdir preferred
            out.u64(UInt64(Int64.max)); out.u32(1); out.u32(0) // max file size, time delta 1 s
            out.u32(0x08) // FSF3_HOMOGENEOUS
        case 20: // PATHCONF
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(1); out.u32(255); out.bool(true); out.bool(true); out.bool(false); out.bool(true)
        default:
            out.u32(Status.notsupp.rawValue)
        }
        return true
    }
}

// MARK: - Writing

extension RemoteDriveServer {
    /// CREATE, WRITE, COMMIT, SETATTR, REMOVE, RENAME, MKDIR, RMDIR on a drive that writes (the backend decides what's allowed).
    fileprivate func nfsWrite(_ procedure: UInt32, path: String, node: RemoteDriveNode, handle: Data,
                              _ input: inout XDRReader, _ out: inout XDRWriter) async throws {
        func after(_ path: String) async -> RemoteDriveNode? { try? await backend.node(path) }
        switch procedure {
        case 2: // SETATTR
            let (size, modified) = try sattr(&input)
            if try input.u32() != 0 { _ = try input.u64() } // guard ctime
            do {
                let changed = size == nil && modified == nil ? node : try await backend.change(path, size: size, modified: modified)
                out.u32(0); wcc(changed, handle: handle, &out)
            } catch { out.u32(status(of: error).rawValue); wcc(node, handle: handle, &out) }
        case 7: // WRITE: always FILE_SYNC (the bytes are on this Mac's disk when the answer goes)
            let offset = try input.u64(); _ = try input.u32(); _ = try input.u32()
            let data = try input.opaque(max: 1 << 20)
            guard !node.folder else { out.u32(Status.isdir.rawValue); wcc(node, handle: handle, &out); return }
            do {
                let written = try await backend.write(path, offset: Int64(clamping: offset), data: data)
                out.u32(0); wcc(written, handle: handle, &out)
                out.u32(UInt32(data.count)); out.u32(2); out.fixed(Self.verifier)
            } catch { out.u32(status(of: error).rawValue); wcc(node, handle: handle, &out) }
        case 21: // COMMIT
            _ = try input.u64(); _ = try input.u32()
            await backend.commit(path)
            out.u32(0); wcc(node, handle: handle, &out); out.fixed(Self.verifier)
        case 8, 9: // CREATE, MKDIR
            let name = try input.string(max: 255)
            var size: Int64?, guarded = procedure == 9
            if procedure == 8 {
                let how = try input.u32()
                guarded = how != 0
                if how == 2 { _ = try input.fixed(8) } else { size = try sattr(&input).size }
            } else { _ = try sattr(&input) }
            guard node.folder else { out.u32(Status.notdir.rawValue); wcc(node, handle: handle, &out); return }
            guard let childPath = Self.child(path, name) else { out.u32(Status.inval.rawValue); wcc(node, handle: handle, &out); return }
            do {
                var made: RemoteDriveNode
                if let there = try? await backend.node(childPath) {
                    // UNCHECKED create of a file that's there: the same file (truncated when asked).
                    guard !guarded, !there.folder else { throw RemoteDriveError.exists }
                    made = there
                } else {
                    made = try await backend.create(childPath, folder: procedure == 9)
                }
                if let size { made = try await backend.change(childPath, size: size, modified: nil) }
                let childHandle = self.handle(childPath)
                out.u32(0); out.bool(true); out.opaque(childHandle); postAttr(made, handle: childHandle, &out)
                wcc(await after(path), handle: handle, &out)
            } catch { out.u32(status(of: error).rawValue); wcc(node, handle: handle, &out) }
        case 12, 13: // REMOVE, RMDIR
            let name = try input.string(max: 255)
            guard let childPath = Self.child(path, name) else { out.u32(Status.inval.rawValue); wcc(node, handle: handle, &out); return }
            do {
                let child = try await backend.node(childPath)
                if procedure == 12, child.folder { throw RemoteDriveError.isFolder }
                if procedure == 13, !child.folder { throw RemoteDriveError.notFolder }
                try await backend.remove(childPath, folder: procedure == 13)
                removed(childPath)
                out.u32(0)
            } catch { out.u32(status(of: error).rawValue) }
            wcc(await after(path), handle: handle, &out)
        case 14: // RENAME (onto a name that's there: the backend replaces it)
            let fromName = try input.string(max: 255)
            let toHandle = try input.opaque(max: 64), toName = try input.string(max: 255)
            guard let toFolder = self.path(toHandle) else {
                out.u32(Status.stale.rawValue); for _ in 0..<4 { out.u32(0) }; return
            }
            let toNode = await after(toFolder)
            // (A folder never moves into itself or its own subfolder.)
            guard let from = Self.child(path, fromName), let to = Self.child(toFolder, toName), toNode?.folder == true, !to.hasPrefix(from + "/") else {
                out.u32(Status.inval.rawValue); wcc(node, handle: handle, &out); wcc(toNode, handle: toHandle, &out); return
            }
            do {
                if from != to { try await backend.rename(from, to: to) }
                moved(from, to: to)
                out.u32(0)
            } catch { out.u32(status(of: error).rawValue) }
            wcc(await after(path), handle: handle, &out); wcc(await after(toFolder), handle: toHandle, &out)
        default:
            out.u32(Status.notsupp.rawValue); wcc(node, handle: handle, &out)
        }
    }
}

// MARK: - Mounting

enum RemoteDriveMount {
    /// mount_nfs options: TCP to one port for MOUNT and NFS, no lock manager (a writable drive keeps locks on this Mac: apps
    /// that lock still work, and the office never sees two writers through one mount), no reserved port (that needs root),
    /// read-only unless it writes, hidden from Finder's sidebar, and soft with short timeouts so a lost host never hangs a reader.
    /// (Read-write only for a drive that writes: RemoteDriveWrite.)
    static func options(port: UInt16, writable: Bool = false) -> String {
        "vers=3,tcp,port=\(port),mountport=\(port),\(writable ? "locallocks" : "nolocks"),noresvport,\(writable ? "" : "rdonly,")nobrowse,soft,intr,timeo=30,retrans=3,deadtimeout=45,nonegnamecache,rsize=1048576,"
            + (writable ? "wsize=1048576," : "") + "readahead=8"
    }

    /// Mounts the server's 127.0.0.1:<export> on `folder` (made if missing). Throws the tool's message on failure.
    static func mount(_ server: RemoteDriveServer, at folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server.allowMount(true)
        defer { server.allowMount(false) }
        let (code, message) = await run("/sbin/mount_nfs", ["-o", options(port: server.port, writable: server.backend.writes), "127.0.0.1:\(server.export)", folder.path])
        if code != 0 { throw NSError(domain: "RemoteDrive", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    /// Unmounts; forced when a plain unmount fails (the host is gone and a reader still holds a file).
    @discardableResult
    static func unmount(_ folder: URL) async -> Bool {
        guard isMounted(folder) else { return true }
        if await run("/sbin/umount", [folder.path]).0 == 0 { return true }
        return await run("/sbin/umount", ["-f", folder.path]).0 == 0
    }

    /// Whether something is mounted right on this folder.
    static func isMounted(_ folder: URL) -> Bool {
        var info = statfs()
        guard statfs(folder.path, &info) == 0 else { return false }
        let point = withUnsafePointer(to: &info.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
        return point == folder.path || point == RemoteEditHost.realPath(folder.path)
    }

    static func run(_ tool: String, _ arguments: [String]) async -> (Int32, String) {
        await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return (-1, "\(tool) didn’t start") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
