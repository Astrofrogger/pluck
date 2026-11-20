import Foundation

/// Renders of remote editors' Resolve projects on the host, one at a time in the order they came:
/// the version's .drp is imported, every proxy swapped for its original, a conform check runs first
/// (problems are reported, nothing is rendered), then Resolve renders with the preset into the share.
/// Kept on disk, so a restart carries on (a render that was going is followed again).
@MainActor
@Observable
final class RemoteRenderQueue {
    nonisolated static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pluck/Office Render", isDirectory: true)
    static let shared = RemoteRenderQueue(file: support.appendingPathComponent("resolve-queue.json"), automatic: true)

    /// A local proxy file on the editor's Mac and the original on the host it stands for.
    struct Proxy: Codable, Hashable, Sendable {
        var file: String
        var share: String
        var path: String
        /// A part of the original pulled to the editor's Mac (RemotePieces), not a proxy.
        var piece: Bool?
    }

    struct Item: Codable, Identifiable {
        enum State: String, Codable { case queued, preparing, rendering, done, problems, failed, cancelled }
        var id = UUID()
        var project: UUID
        var projectName: String
        var version: Int
        var timeline: String
        var preset: String
        var share: String?
        var proxies: [Proxy]
        var device: String
        var deviceID: UUID
        var added = Date.now
        var state = State.queued
        var progress = 0.0
        var remaining: Double?
        var problems: [String] = []
        var resolveProject: String?
        var resolveJob: String?
        var file: String?
        var preview: String?
        var previewSize: Int64?
        var making = false

        var open: Bool { state == .queued || state == .preparing || state == .rendering }

        /// What a paired Mac is told (file names, never paths on this Mac).
        func summary(for device: UUID, position: Int?) -> [String: Any] {
            var result: [String: Any] = ["id": id.uuidString, "project": projectName, "version": version, "timeline": timeline,
                                         "preset": preset, "device": self.device, "mine": deviceID == device, "state": state.rawValue,
                                         "progress": progress, "problems": problems, "added": added.timeIntervalSince1970,
                                         "makingPreview": making]
            if let position { result["position"] = position }
            if let remaining { result["remaining"] = remaining }
            if let file { result["file"] = URL(fileURLWithPath: file).lastPathComponent }
            if let previewSize { result["previewSize"] = previewSize }
            return result
        }
    }

    let file: URL
    private let automatic: Bool
    private(set) var items: [Item] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    var isBusy: Bool { items.contains { $0.state == .preparing || $0.state == .rendering } }

    init(file: URL, automatic: Bool) {
        self.file = file
        self.automatic = automatic
        items = (try? JSONDecoder().decode([Item].self, from: Data(contentsOf: file))) ?? []
        // Cut short while getting ready: from the start again. A render that was going is followed again.
        for index in items.indices where items[index].state == .preparing { items[index].state = .queued }
        for index in items.indices { items[index].making = false }
        if automatic, items.contains(where: \.open) { Task { self.pump() } }
    }

    /// The order of the waiting ones (1 = next).
    func position(_ id: UUID) -> Int? {
        items.filter { $0.state == .queued }.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// The next to run: one that was rendering (after a restart), else the oldest waiting one.
    var next: Item? { items.first { $0.state == .rendering } ?? items.first { $0.state == .queued } }

    @discardableResult
    func add(_ item: Item) -> Item {
        items.append(item)
        save()
        pump()
        return item
    }

    /// `device` nil: the host cancels any.
    func cancel(_ id: UUID, by device: UUID?) async throws {
        guard let index = items.firstIndex(where: { $0.id == id && (device == nil || $0.deviceID == device) }) else {
            throw OfficeLink.Failure.office(String(localized: "That render isn’t on the host Mac any more."))
        }
        guard items[index].open else { return }
        let was = items[index]
        items[index].state = .cancelled
        save()
        if was.state == .rendering, let project = was.resolveProject, let job = was.resolveJob {
            _ = try? await OfficeResolve.run(["action": "stop", "name": project, "job": job])
        }
    }

    func clearFinished() {
        for item in items where !item.open {
            if let preview = item.preview { try? FileManager.default.removeItem(atPath: preview) }
        }
        items.removeAll { !$0.open }
        save()
    }

    func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Every open one, and the last 100 finished.
        let finished = items.filter { !$0.open }.suffix(100).map(\.id)
        let kept = items.filter { $0.open || finished.contains($0.id) }
        if let data = try? JSONEncoder().encode(kept) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: - Running

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    func pump() {
        guard automatic, worker == nil else { return }
        worker = Task {
            while !Task.isCancelled, let item = next {
                // The older Edit Anywhere renders (projects from the library) go first.
                if OfficeRenderServer.shared.isRendering {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                await process(item.id)
            }
            worker = nil
        }
    }

    private func process(_ id: UUID) async {
        guard let item = item(id) else { return }
        if item.state == .rendering { return await follow(id) }
        update(id) { $0.state = .preparing; $0.problems = [] }
        do {
            let drp = RemoteCheckout.shared.file(item.project, version: item.version)
            guard FileManager.default.fileExists(atPath: drp.path) else {
                throw OfficeLink.Failure.office(String(localized: "That version isn’t on the host Mac any more."))
            }
            let name = RemoteResolveProject.hostName(item.projectName, id: item.project)
            let inspected = try await RemoteResolveScript.run(["action": "inspect", "name": name, "drp": drp.path, "timeline": item.timeline,
                                                               "label": item.projectName])
            guard self.item(id)?.state == .preparing else { return }
            var problems: [String] = []
            if !(inspected["timelines"] as? [String] ?? []).contains(item.timeline) {
                problems.append(String(localized: "The timeline \(item.timeline) isn’t in this version."))
            }
            if !(inspected["presets"] as? [String] ?? []).contains(item.preset) {
                problems.append(String(localized: "The render preset \(item.preset) isn’t on the host Mac."))
            }
            // What Fusion and grades reach must stay in the shares, unless the owner trusts that Mac fully.
            let trusted = OfficeRenderServer.shared.devices.first { $0.id == item.deviceID }?.allowed.fullTrust == true
            problems += RemoteResolveProject.uses(inspected, roots: RemoteResolveProject.shareRoots(), builtIn: RemoteResolveProject.builtInRoots,
                                                  trusted: trusted).prefix(20)
            let clips = (inspected["items"] as? [[String: Any]] ?? []).map(RemoteResolveProject.Clip.init)
            let plan = await RemoteResolveProject.conform(clips, proxies: item.proxies, trusted: trusted)
            problems += plan.problems
            guard problems.isEmpty else {
                update(id) { $0.state = .problems; $0.problems = problems }
                return
            }
            let target = try RemoteResolveProject.renderFolder(share: item.share ?? item.proxies.first?.share, project: item.projectName)
            let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                                     timeZone: .current, calendar: .current))
            let answer = try await RemoteResolveScript.run(["action": "render", "name": name, "swaps": plan.swaps,
                                                            // (A copy with its multicam clips flattened, when it has any.)
                                                            "timeline": inspected["render"] as? String ?? item.timeline,
                                                            "preset": item.preset, "target": target.path,
                                                            "output": Folders.sanitize(item.timeline) + " v\(item.version) " + stamp])
            guard let job = answer["job"] as? String else { throw OfficeLink.Failure.office(String(localized: "DaVinci Resolve couldn’t start rendering.")) }
            if self.item(id)?.state == .cancelled {
                _ = try? await OfficeResolve.run(["action": "stop", "name": name, "job": job])
                return
            }
            update(id) { $0.state = .rendering; $0.resolveProject = name; $0.resolveJob = job }
            await follow(id)
        } catch let failure as ResolveBridge.Failure where failure.message == "busy" {
            // Resolve is rendering something else: wait and try again, still first in line.
            update(id) { if $0.state == .preparing { $0.state = .queued } }
            try? await Task.sleep(for: .seconds(10))
        } catch {
            update(id) {
                guard $0.state == .preparing else { return }
                $0.state = .failed
                $0.problems = [error.localizedDescription]
            }
        }
    }

    /// Asks Resolve how the render is going every few seconds until it ends.
    private func follow(_ id: UUID) async {
        while let item = item(id), item.state == .rendering, let project = item.resolveProject, let job = item.resolveJob {
            if let answer = try? await OfficeResolve.run(["action": "status", "name": project, "jobs": [job]]) {
                let status = (answer["status"] as? [String: [String: Any]])?[job]
                guard self.item(id)?.state == .rendering else { return }
                guard answer["elsewhere"] == nil, let status, status["exists"] as? Bool == true else {
                    update(id) { $0.state = .failed; $0.problems = [String(localized: "The render was removed from DaVinci Resolve on the host Mac.")] }
                    return
                }
                update(id) {
                    $0.progress = Double(status["CompletionPercentage"] as? Int ?? 0) / 100
                    $0.remaining = (status["EstimatedTimeRemainingInMs"] as? Double).map { $0 / 1000 }
                    if let file = status["file"] as? String, !file.isEmpty { $0.file = file }
                    switch status["JobStatus"] as? String ?? "" {
                    case "Complete": $0.state = .done; $0.progress = 1; $0.remaining = nil
                    case "Failed": $0.state = .failed; $0.problems = [status["Error"] as? String ?? String(localized: "DaVinci Resolve couldn’t render it.")]
                    case "Cancelled", "Background Render Cancelled": $0.state = .cancelled
                    default: break
                    }
                }
                if self.item(id)?.state == .done { await makePreview(id) }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// A small copy to send home: 540p H.264, as OfficeRenderServer makes for its renders.
    private func makePreview(_ id: UUID) async {
        guard let file = item(id)?.file, FileManager.default.fileExists(atPath: file),
              let ffmpeg = OfficeRenderServer.shared.manager?.tool("ffmpeg") else { return }
        let folder = Self.support.appendingPathComponent("Resolve Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(id.uuidString + ".mp4")
        update(id) { $0.making = true }
        let ok = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", file, "-map", "0:v:0", "-map", "0:a:0?",
                                 "-vf", "scale=-2:'min(540,ih)'", "-c:v", "h264_videotoolbox", "-b:v", "1400k",
                                 "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", target.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
        update(id) {
            $0.making = false
            if ok, let size { $0.preview = target.path; $0.previewSize = size }
        }
    }
}
