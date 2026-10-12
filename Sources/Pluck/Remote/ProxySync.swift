import Foundation
import Observation

/// Proxies of the host Mac's footage, fetched to this Mac in the background: the host makes them
/// one by one, and each is fetched as soon as it's ready, in pieces, carrying on where it stopped.
/// They land in a folder here with the originals' folder structure and names, for Resolve's
/// Link Proxy Media.
@MainActor
@Observable
final class ProxySync {
    static let shared = ProxySync()
    private static let jobsKey = "editAnywhereProxyJobs"

    /// A footage folder on the host this Mac keeps proxies of.
    struct Job: Codable, Identifiable, Equatable {
        var folder: String
        var name: String
        var format: OfficeProxies.Format
        var destination: String
        var id: String { folder + "-" + format.rawValue }
    }

    /// How a job stands, from the host's last answer.
    struct Progress: Equatable {
        var total = 0
        var madeOnHost = 0
        var here = 0
        /// The file being fetched now and how far along.
        var fetching: String?
        var fraction = 0.0
        /// The file the host is making now.
        var making: String?
        var problem: String?
    }

    struct Folder: Identifiable, Equatable {
        var id: String
        var name: String
        var files: Int
    }

    private(set) var jobs: [Job] = []
    private(set) var progress: [Job.ID: Progress] = [:]
    private(set) var folders: [Folder] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.jobsKey), let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: Self.jobsKey) }
    }

    static var defaultDestination: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck Proxies", isDirectory: true)
    }

    private var client: OfficeRenderClient { OfficeRenderClient.shared }

    func loadFolders() async throws {
        let answer = try await client.ask("proxyFolders", timeout: 60)
        folders = (answer["folders"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return Folder(id: id, name: name, files: item["files"] as? Int ?? 0)
        }
    }

    /// Asks the host to make proxies of a folder and starts fetching them into `parent`/<folder name>.
    func start(_ folder: Folder, format: OfficeProxies.Format, parent: URL) async throws {
        _ = try await client.ask("proxyMake", ["folder": folder.id, "format": format.rawValue])
        let name = Folders.sanitize(folder.name) + (format == .original ? " " + String(localized: "(Originals)") : "")
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        let job = Job(folder: folder.id, name: folder.name, format: format, destination: destination.path)
        jobs.removeAll { $0.id == job.id }
        jobs.append(job)
        save()
        resume()
    }

    /// Stops fetching a folder's proxies; what's fetched stays.
    func remove(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        progress[job.id] = nil
        save()
    }

    /// Keeps fetching while there's anything to fetch: looks at the host every half minute
    /// while it's still making proxies, and stops when everything is here.
    func resume() {
        guard task == nil, !jobs.isEmpty, client.office != nil, ScreenshotMode.scene == nil || ["proxytest", "sendtest"].contains(ScreenshotMode.scene) else { return }
        task = Task {
            defer { task = nil }
            while !Task.isCancelled, client.office != nil {
                var waiting = false
                for job in jobs where !Task.isCancelled {
                    if await sync(job) { waiting = true }
                }
                guard waiting else { return }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Fetches what's ready of one folder. True while there's more to come.
    private func sync(_ job: Job) async -> Bool {
        var state = progress[job.id] ?? Progress()
        let answer: [String: Any]
        do {
            answer = try await client.ask("proxyStatus", ["folder": job.folder, "format": job.format.rawValue], timeout: 60)
        } catch {
            state.problem = error.localizedDescription
            progress[job.id] = state
            return true
        }
        if answer["asked"] as? Bool == false {
            // The host forgot it (it tidies proxies nobody asked about for weeks): ask again.
            _ = try? await client.ask("proxyMake", ["folder": job.folder, "format": job.format.rawValue])
        }
        let files = (answer["files"] as? [[String: Any]] ?? []).compactMap { item -> (path: String, size: Int64?)? in
            guard let path = item["path"] as? String, Self.isSafe(path) else { return nil }
            return (path, (item["size"] as? NSNumber)?.int64Value)
        }
        let destination = URL(fileURLWithPath: job.destination, isDirectory: true)
        state.problem = nil
        state.total = files.count
        state.madeOnHost = files.filter { $0.size != nil }.count
        state.making = answer["working"] as? String
        state.here = files.filter { file in
            guard let size = file.size else { return false }
            return Self.size(of: Self.local(file.path, in: destination, format: job.format)) == size
        }.count
        progress[job.id] = state

        for file in files where !Task.isCancelled && jobs.contains(job) {
            guard let size = file.size else { continue }
            let target = Self.local(file.path, in: destination, format: job.format)
            guard Self.size(of: target) != size else { continue }
            do {
                try await fetch(file.path, size: size, of: job, to: target)
                progress[job.id]?.here += 1
            } catch {
                progress[job.id]?.problem = error.localizedDescription
                break
            }
        }
        progress[job.id]?.fetching = nil
        let done = progress[job.id].map { $0.here >= $0.total && $0.total > 0 } ?? false
        return !done
    }

    private func fetch(_ path: String, size: Int64, of job: Job, to target: URL) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("part")
        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: partial.path) else {
            throw OfficeLink.Failure.office(String(localized: "The proxy couldn’t be saved on this Mac."))
        }
        defer { try? handle.close() }
        // Carries on from what an earlier try fetched.
        var offset = Int(try handle.seekToEnd())
        progress[job.id]?.fetching = (path as NSString).lastPathComponent
        while offset < size, !Task.isCancelled {
            let answer = try await client.ask("proxyData", ["folder": job.folder, "format": job.format.rawValue, "path": path, "offset": offset], timeout: 120)
            guard let chunk = (answer["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw OfficeLink.Failure.garbled }
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
            offset += chunk.count
            progress[job.id]?.fraction = Double(offset) / Double(max(size, 1))
        }
        guard offset >= size else { return }
        try handle.close()
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
    }

    /// Where a proxy goes here: its path inside the folder, as a .mov (originals keep their own).
    private static func local(_ path: String, in destination: URL, format: OfficeProxies.Format) -> URL {
        format == .original ? destination.appendingPathComponent(path)
            : destination.appendingPathComponent((path as NSString).deletingPathExtension + ".mov")
    }

    /// A path inside the folder (the host's answer is trusted only this far).
    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && path.count < 1000
    }

    private static func size(of file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }
}
