import Foundation
import Observation

/// Files sent from this Mac to the host Mac: folders kept in step (new and changed files go up
/// by themselves) and one-off files. They land in this Mac's folder in the host's inbox; a file
/// that stopped half-way carries on from where it got to.
@MainActor
@Observable
final class SendSync {
    static let shared = SendSync()
    private static let foldersKey = "editAnywhereSendFolders"
    private static let filesKey = "editAnywhereSendFiles"
    private static let officeKey = "editAnywhereSendOffice"
    /// The office Macs files go to, the paired one first (`officeKey` is the single one of builds before; still written).
    static let officesKey = "editAnywhereSendOffices"

    /// When a file was sent, so it's only sent again when it changes.
    struct Stamp: Codable, Equatable {
        var size: Int64
        var modified: Double
    }

    struct Folder: Codable, Identifiable, Equatable {
        var path: String
        /// What the first office Mac has.
        var sent: [String: Stamp] = [:]
        /// What each other office Mac it goes to has (by its id; nil in folders saved before).
        var sentTo: [String: [String: Stamp]]?
        var id: String { path }

        func sent(at office: UUID?, first: Bool) -> [String: Stamp] { first ? sent : sentTo?[office?.uuidString ?? ""] ?? [:] }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    }

    private(set) var folders: [Folder] = []
    /// One-off files still to send.
    private(set) var files: [String] = []
    /// The file going up now, how far along, and how many wait.
    private(set) var sending: String?
    private(set) var fraction = 0.0
    private(set) var waiting = 0
    private(set) var lastSent: Date?
    private(set) var problem: String?
    /// The office Macs these folders and files go to, the one they were set up for first: a different paired host waits
    /// for a yes. The others are office Macs of its group (each gets its own transfer, carried on where it stopped).
    private(set) var offices: [UUID] = []
    /// The host these folders and files were set up for.
    var office: UUID? {
        get { offices.first }
        set { offices = newValue.map { [$0] } ?? [] }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var passing = false
    /// What it's doing, step by step (the self-test).
    @ObservationIgnored var trace: ((String) -> Void)?

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.foldersKey), let saved = try? JSONDecoder().decode([Folder].self, from: data) { folders = saved }
        files = defaults.stringArray(forKey: Self.filesKey) ?? []
        offices = Self.offices(list: defaults.stringArray(forKey: Self.officesKey), single: defaults.string(forKey: Self.officeKey))
    }

    /// The saved list, or the single office of builds before.
    nonisolated static func offices(list: [String]?, single: String?) -> [UUID] {
        (list ?? single.map { [$0] } ?? []).compactMap(UUID.init(uuidString:))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(data, forKey: Self.foldersKey) }
        UserDefaults.standard.set(files, forKey: Self.filesKey)
        UserDefaults.standard.set(office?.uuidString, forKey: Self.officeKey)
        UserDefaults.standard.set(offices.map(\.uuidString), forKey: Self.officesKey)
    }

    /// Also send to (or stop sending to) another office Mac of the group.
    func setAlso(_ member: UUID, _ on: Bool) {
        guard let first = office, member != first else { return }
        offices.removeAll { $0 == member }
        if on { offices.append(member) }
        save()
        resume()
    }

    /// Where a pass sends: the paired host, then the other chosen office Macs still in its group.
    private var destinations: [UUID?] {
        let members = Set(client.members.map(\.id))
        return [nil] + offices.dropFirst().filter { members.contains($0) }.map { Optional($0) }
    }

    /// The paired host isn't the one these were set up for (an invitation replaced it).
    var needsConfirm: Bool {
        guard let paired = client.office?.device, let office else { return false }
        return paired != office && !(folders.isEmpty && files.isEmpty)
    }

    /// Yes: keep sending, to the host paired now.
    func keep() {
        office = client.office?.device
        save()
        resume()
    }

    /// No: stop sending all of them (nothing on this Mac is touched).
    func stop() {
        task?.cancel()
        folders = []
        files = []
        office = nil
        save()
    }

    /// Ties what's waiting to the host paired now, the first time there is one.
    private func bind() {
        if office == nil, let paired = client.office?.device { office = paired; save() }
    }

    private var client: OfficeRenderClient { OfficeRenderClient.shared }

    /// Nothing waiting: what's chosen next goes to the host paired now, without asking.
    private func forgetHostIfIdle() {
        if folders.isEmpty && files.isEmpty { office = nil }
    }

    func add(folder: URL) {
        guard !folders.contains(where: { $0.path == folder.path }) else { return }
        forgetHostIfIdle()
        folders.append(Folder(path: folder.path))
        bind()
        save()
        resume()
    }

    func remove(_ folder: Folder) {
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func send(_ urls: [URL]) {
        forgetHostIfIdle()
        for url in urls where !files.contains(url.path) {
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                add(folder: url)
            } else {
                files.append(url.path)
            }
        }
        bind()
        save()
        resume()
    }

    /// Keeps sending while paired: the one-off files, then whatever changed in the folders, and
    /// a fresh look at the folders every minute.
    func resume() {
        bind()
        guard task == nil, client.office != nil, !needsConfirm, !(folders.isEmpty && files.isEmpty),
              ScreenshotMode.scene == nil || ScreenshotMode.scene == "sendtest" else { return }
        task = Task {
            defer { task = nil; sending = nil }
            while !Task.isCancelled, client.office != nil, !needsConfirm, !(folders.isEmpty && files.isEmpty) {
                await pass()
                try? await Task.sleep(for: .seconds(problem == nil ? 60 : 120))
            }
        }
    }

    /// Sends what's waiting now. Stops at the first problem (the host is away, say) and tries
    /// again on the next pass.
    func pass() async {
        // One pass at a time (a second would send the same files again).
        guard !passing, !needsConfirm else { return }
        passing = true
        defer { passing = false }
        problem = nil
        // One-off files first, into the top of this Mac's folder.
        // Each office Mac in turn: one that's away doesn't hold up the others (it catches up on a later pass).
        let targets = destinations
        var left = files
        for path in files {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { left.removeAll { $0 == path }; continue }
            waiting = files.count - 1
            var all = true
            for target in targets {
                do { try await upload(url, as: url.lastPathComponent, to: target) } catch {
                    if needsConfirm { return }
                    problem = problem ?? error.localizedDescription
                    all = false
                }
            }
            if all { left.removeAll { $0 == path } }
        }
        if left != files { files = left; save() }
        for (place, target) in targets.enumerated() {
            for folder in folders {
                let sent = folder.sent(at: target, first: place == 0)
                let changed = await Task.detached { Self.changes(in: folder, sent: sent) }.value
                for (number, change) in changed.enumerated() {
                    waiting = changed.count - number - 1
                    do {
                        try await upload(folder.url.appendingPathComponent(change.relative), as: folder.url.lastPathComponent + "/" + change.relative, to: target)
                        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
                            if let target { folders[index].sentTo = folders[index].sentTo ?? [:]; folders[index].sentTo![target.uuidString, default: [:]][change.relative] = change.stamp }
                            else { folders[index].sent[change.relative] = change.stamp }
                            save()
                        }
                    } catch {
                        if needsConfirm { return }
                        problem = problem ?? error.localizedDescription
                        break
                    }
                }
            }
        }
        waiting = 0
    }

    /// Files in a folder that are new or changed since they were sent, leaving out hidden files
    /// and ones still being written (changed in the last few seconds).
    nonisolated private static func changes(in folder: Folder, sent: [String: Stamp]) -> [(relative: String, stamp: Stamp)] {
        let root = folder.url.standardizedFileURL
        let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var found: [(String, Stamp)] = []
        while let url = items?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true, let size = values.fileSize, let date = values.contentModificationDate,
                  Date.now.timeIntervalSince(date) > 10 else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            let stamp = Stamp(size: Int64(size), modified: date.timeIntervalSince1970.rounded())
            if sent[relative] != stamp { found.append((relative, stamp)) }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    /// One file to the host (`office` nil) or another office Mac of its group, in pieces, from where that Mac has got to.
    private func upload(_ url: URL, as path: String, to office: UUID? = nil) async throws {
        // (Checked per file: the host can change in the middle of a pass.)
        guard !needsConfirm else { throw CancellationError() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values.fileSize ?? 0)
        let modified = (values.contentModificationDate ?? .now).timeIntervalSince1970.rounded()
        let file = ["path": path, "size": size, "modified": modified] as [String: Any]
        sending = url.lastPathComponent
        fraction = 0
        defer { sending = nil }
        trace?("asking about \(path)")
        var have = (try await client.ask(on: office, "sendState", file)["have"] as? NSNumber)?.int64Value ?? 0
        trace?("host has \(have) of \(size)")
        guard have < size || size == 0 else { lastSent = .now; return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var restarted = false
        repeat {
            guard !needsConfirm else { throw CancellationError() }
            try handle.seek(toOffset: UInt64(have))
            let chunk = try handle.read(upToCount: OfficeLink.uploadChunk) ?? Data()
            var piece = file
            piece["offset"] = have
            piece["data"] = chunk.base64EncodedString()
            do {
                have = (try await client.ask(on: office, "send", piece, timeout: 120)["have"] as? NSNumber)?.int64Value ?? have
            } catch OfficeLink.Failure.office(_) where !restarted {
                // The host had a different part (an earlier try of a changed file): start over once.
                restarted = true
                have = 0
                continue
            }
            fraction = size > 0 ? Double(have) / Double(size) : 1
            if chunk.isEmpty { break }
        } while have < size
        lastSent = .now
    }
}
