import Foundation

/// Files paired Macs send to this Mac (graphics, music, a voice-over, project files): each Mac
/// gets its own folder in the inbox, and can only write there. A file arrives in pieces, as a
/// hidden partial file, and appears under its name when it's complete.
@MainActor
@Observable
final class OfficeInbox {
    static let shared = OfficeInbox()
    private static let folderKey = "officeInboxFolder"
    /// The largest file a paired Mac can send.
    private static let largest: Int64 = 500_000_000_000

    /// Where files from paired Macs go: chosen here, or Movies/Pluck Inbox.
    private(set) var folder: URL
    /// The file arriving now, and how far along.
    private(set) var receiving: String?
    private(set) var progress = 0.0
    /// The last files that arrived (newest first), for the host to see.
    private(set) var recent: [(name: String, from: String, at: Date)] = []

    static var defaultFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck Inbox", isDirectory: true)
    }

    private init() {
        folder = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    func choose(_ folder: URL?) throws {
        if let folder {
            // (Inside shared footage, files paired Macs send would become proxy and search inputs;
            // around it, the footage would be left out of search as part of the inbox.)
            let path = folder.standardizedFileURL.path + "/"
            guard !OfficeArchive.shared.folders.contains(where: { footage in
                let other = footage.standardizedFileURL.path + "/"
                return path.hasPrefix(other) || other.hasPrefix(path)
            }) else { throw OfficeProxies.ChoiceProblem.overlapsFootage }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: folder.path) else { throw OfficeProxies.ChoiceProblem.notWritable }
        }
        self.folder = folder ?? Self.defaultFolder
        UserDefaults.standard.set(folder?.path, forKey: Self.folderKey)
    }

    enum Problem: LocalizedError {
        case badPath, tooBig, mismatch
        var errorDescription: String? {
            switch self {
            case .badPath: String(localized: "That file name can’t be used on the host Mac.")
            case .tooBig: String(localized: "That file is too big to send.")
            case .mismatch: String(localized: "The file changed while it was being sent. It starts again.")
            }
        }
    }

    /// A paired Mac's own folder in the inbox: its name and id (two Macs may share a name).
    static func folderName(_ name: String, id: UUID) -> String {
        let clean = Folders.sanitize(name)
        return (clean.isEmpty ? "Mac" : clean) + " " + id.uuidString.prefix(8)
    }

    /// The file's place: <inbox>/<Mac's folder>/<its path>. Only plain paths inside it.
    func target(_ path: String, from device: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.count < 1000, parts.count <= 32,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains(":") }) else {
            throw Problem.badPath
        }
        let macFolder = folder.appendingPathComponent(Folders.sanitize(device).isEmpty ? "Mac" : Folders.sanitize(device), isDirectory: true)
        return parts.reduce(macFolder) { $0.appendingPathComponent($1) }
    }

    /// (Named by the sender's size and date, so a part of an earlier version is never added to.)
    private static func partial(_ target: URL, size: Int64, modified: Double) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(size)-\(Int64(modified)).pluckpart")
    }

    private static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// How much of a file is here: all of it when the same file (size and date) arrived before,
    /// the part received so far otherwise.
    func have(_ path: String, size: Int64, modified: Double, from device: String) throws -> Int64 {
        let target = try target(path, from: device)
        if Self.size(target) == size,
           let date = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           abs(date.timeIntervalSince1970 - modified) < 2 {
            return size
        }
        return Self.size(Self.partial(target, size: size, modified: modified)) ?? 0
    }

    /// One piece of a file, at the end of what's here. The piece that completes it puts the file
    /// in place (replacing an earlier version from the same Mac) with the sender's date.
    func receive(_ path: String, size: Int64, modified: Double, offset: Int64, data: Data, from device: String, sender: String? = nil) throws -> Int64 {
        guard size >= 0, size <= Self.largest, offset >= 0, offset + Int64(data.count) <= size else { throw Problem.tooBig }
        let target = try target(path, from: device)
        let partial = Self.partial(target, size: size, modified: modified)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // (A folder of that name stays: never replaced by a file.)
        var isFolder: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue { throw Problem.badPath }
        if offset == 0 {
            // (Only Pluck's own hidden parts of this file, any version.)
            let stem = "." + target.lastPathComponent + "."
            for name in (try? fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []
            where name.hasPrefix(stem) && name.hasSuffix(".pluckpart") {
                try? fm.removeItem(at: target.deletingLastPathComponent().appendingPathComponent(name))
            }
        }
        let here = Self.size(partial) ?? 0
        // Only ever added to at its end; anything else and the sender starts that file again.
        guard here == offset else {
            if here > offset { try? FileManager.default.removeItem(at: partial) }
            throw Problem.mismatch
        }
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        let now = offset + Int64(data.count)
        receiving = target.lastPathComponent
        progress = size > 0 ? Double(now) / Double(size) : 1
        if now == size {
            try handle.close()
            // (The earlier version goes to the Trash, or beside it on a drive without one: never deleted.)
            if fm.fileExists(atPath: target.path), (try? fm.trashItem(at: target, resultingItemURL: nil)) == nil {
                let taken = Set(((try? fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []).map { $0.lowercased() })
                try fm.moveItem(at: target, to: target.deletingLastPathComponent().appendingPathComponent(FileClash.freeName(target.lastPathComponent, taken: taken)))
            }
            try fm.moveItem(at: partial, to: target)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: target.path)
            receiving = nil
            recent.insert((target.lastPathComponent, sender ?? device, .now), at: 0)
            if recent.count > 20 { recent.removeLast(recent.count - 20) }
        }
        return now
    }
}
