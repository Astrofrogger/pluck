import CryptoKit
import Foundation
import Network

/// Pluck's own drive: a tiny read-only NFSv3 server (RFC 1813, ONC RPC RFC 5531, XDR RFC 4506) on
/// 127.0.0.1, so a share streamed from the host mounts with plain `mount_nfs` (no File Sharing, no admin,
/// no extra install). It knows nothing about the host: a `RemoteDriveBackend` answers for paths.
/// Paths are share-proxy relative, "" for the top, "a/b.mov" below it.

struct RemoteDriveNode: Sendable, Equatable {
    var name: String
    var folder: Bool
    var size: Int64
    var modified: Date
}

enum RemoteDriveError: Error { case noEntry, io, notFolder }

protocol RemoteDriveBackend: AnyObject, Sendable {
    func node(_ path: String) async throws -> RemoteDriveNode
    func list(_ path: String) async throws -> [RemoteDriveNode]
    func read(_ path: String, offset: Int64, count: Int) async throws -> Data
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
        case ok = 0, noent = 2, io = 5, acces = 13, notdir = 20, isdir = 21, inval = 22, rofs = 30
        case stale = 70, badhandle = 10001, badCookie = 10003, notsupp = 10004, serverfault = 10006
    }

    let backend: RemoteDriveBackend
    /// The export name mount_nfs asks for ("/pluck").
    let export: String
    private let queue = DispatchQueue(label: "pluck.drive")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private var paths: [Data: String] = [:]
    private(set) var port: UInt16 = 0
    /// Any process on this Mac can reach 127.0.0.1, so the root handle is only given out while Pluck itself
    /// mounts, and handles are salted per run (no guessing one from a path).
    private static let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    private var mounting = false
    func allowMount(_ open: Bool) { lock.lock(); mounting = open; lock.unlock() }

    init(backend: RemoteDriveBackend, export: String = "/pluck") {
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
        let value = Data(SHA256.hash(data: Self.salt + Data(path.utf8)).prefix(16))
        lock.lock(); paths[value] = path; lock.unlock()
        return value
    }

    func path(_ handle: Data) -> String? {
        lock.lock(); defer { lock.unlock() }
        return paths[handle]
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
              let procedure = try? input.u32(), let flavor = try? input.u32(), (try? input.opaque(max: 400)) != nil,
              (try? input.u32()) != nil, (try? input.opaque(max: 400)) != nil else { return nil }
        guard rpcVersion == 2 else {
            out.u32(1); out.u32(0); out.u32(2); out.u32(2) // MSG_DENIED, RPC_MISMATCH 2...2
            return out.data
        }
        guard flavor == 0 || flavor == 1 else { // AUTH_NONE / AUTH_SYS only
            out.u32(1); out.u32(1); out.u32(1) // MSG_DENIED, AUTH_ERROR, AUTH_BADCRED
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
        case 5: // EXPORT
            out.bool(true); out.string(export); out.bool(false); out.bool(false)
        default: return false
        }
        return true
    }

    // MARK: NFS v3

    private func fattr(_ node: RemoteDriveNode, handle: Data, _ out: inout XDRWriter) {
        out.u32(node.folder ? 2 : 1)
        out.u32(node.folder ? 0o555 : 0o444)
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
        default: .io
        }
    }

    private func nfs(_ procedure: UInt32, _ input: inout XDRReader, _ out: inout XDRWriter) async throws -> Bool {
        if procedure == 0 { return true }
        // Writing procedures: read-only file system, with their empty "failure" bodies.
        let emptyWcc: [UInt32: Int] = [2: 2, 7: 2, 8: 2, 9: 2, 10: 2, 11: 2, 12: 2, 13: 2, 14: 4, 15: 3, 21: 2]
        if let zeros = emptyWcc[procedure] {
            out.u32(Status.rofs.rawValue)
            for _ in 0..<zeros { out.u32(0) }
            return true
        }
        guard procedure <= 21 else { return false }
        let handle = try input.opaque(max: 64)
        guard let path = path(handle) else {
            out.u32(Status.stale.rawValue)
            if procedure != 1 { out.u32(0) } // every failure body but GETATTR's starts with an (empty) post_op_attr
            return true
        }
        let node: RemoteDriveNode
        do { node = try await backend.node(path) } catch {
            out.u32(status(of: error).rawValue)
            if procedure != 1 { out.u32(0) }
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
        case 4: // ACCESS: read, lookup, execute (for folders) only
            let asked = try input.u32()
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(asked & (node.folder ? 0x23 : 0x21))
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
            out.u64(1 << 40); out.u64(0); out.u64(0); out.u64(1 << 20); out.u64(0); out.u64(0); out.u32(1)
        case 19: // FSINFO
            out.u32(0); postAttr(node, handle: handle, &out)
            out.u32(1 << 20); out.u32(1 << 20); out.u32(4096) // read max, preferred, multiple
            out.u32(1 << 20); out.u32(1 << 20); out.u32(4096) // write (unused)
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

// MARK: - Mounting

enum RemoteDriveMount {
    /// mount_nfs options: TCP to one port for MOUNT and NFS, no lock manager, no reserved port (that needs root),
    /// read-only, hidden from Finder's sidebar, and soft with short timeouts so a lost host never hangs a reader.
    static func options(port: UInt16) -> String {
        "vers=3,tcp,port=\(port),mountport=\(port),nolocks,noresvport,rdonly,nobrowse,soft,intr,timeo=30,retrans=3,deadtimeout=45,nonegnamecache,rsize=1048576,readahead=8"
    }

    /// Mounts the server's 127.0.0.1:/pluck on `folder` (made if missing). Throws the tool's message on failure.
    static func mount(_ server: RemoteDriveServer, at folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        server.allowMount(true)
        defer { server.allowMount(false) }
        let (code, message) = await run("/sbin/mount_nfs", ["-o", options(port: server.port), "127.0.0.1:\(server.export)", folder.path])
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
