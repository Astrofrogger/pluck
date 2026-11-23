import Foundation
import Observation

/// Delivery Check's queue and what was found, kept when the page is left (the check goes on in the
/// background) and across launches (the reports, saved small).
@MainActor @Observable
final class DeliveryCheckStore {
    static let shared = DeliveryCheckStore(url: defaultURL)

    /// A file in the queue and what was found in it.
    struct Item: Identifiable {
        var id = UUID()
        var file: URL
        /// The spec it goes out to; nil: the queue's.
        var specID: String?
        var report: DeliveryCheck.Report?
        var failed: String?
        /// The approved earlier version it was compared with.
        var approved: URL?
    }

    var items: [Item] = []
    var current: Item.ID?
    var running: Task<Void, Never>?
    var progress = 0.0
    var stage = ""
    var problem: String?
    /// Counts up whenever a file's check ends (the page re-reads what it shows).
    var revision = 0
    @ObservationIgnored private let url: URL?
    @ObservationIgnored static let keep = 30

    static var defaultURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Delivery Check Queue.json")
    }

    /// `url`: where the queue is kept (nil: nowhere).
    init(url: URL?) {
        self.url = url
        load()
    }

    // MARK: - Queue

    /// The queue is these files (checked now), or they join it.
    func open(_ urls: [URL], append: Bool = false, manager: DownloadManager?) {
        guard running == nil else { return }
        var added: [Item] = []
        if append {
            // A file already queued is checked again, at the end.
            for url in urls {
                var item = items.firstIndex { $0.file == url }.map { items.remove(at: $0) } ?? Item(file: url)
                item.report = nil
                item.failed = nil
                items.append(item)
                added.append(item)
            }
        } else {
            items = urls.map { Item(file: $0) }
            added = items
        }
        problem = nil
        current = added.first?.id
        save()
        check(all: false, manager: manager)
    }

    func setSpec(_ specID: String?, for id: Item.ID, manager: DownloadManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].specID != specID else { return }
        items[index].specID = specID
        items[index].report = nil
        items[index].failed = nil
        save()
        check(all: false, manager: manager)
    }

    func setApproved(_ approved: URL, for id: Item.ID, manager: DownloadManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].approved = approved
        items[index].report = nil
        save()
        check(all: false, manager: manager)
    }

    /// The spec a file is checked against.
    func spec(of item: Item) -> DeliveryCheck.Spec {
        DeliveryCheck.spec(id: item.specID ?? UserDefaults.standard.string(forKey: "deliveryCheckDestination") ?? DeliveryCheck.Destination.online.rawValue)
    }

    // MARK: - Checking

    /// Checks the queue one file after another (all of them, or only those not checked yet).
    func check(all: Bool, manager: DownloadManager?) {
        guard running == nil, !items.isEmpty else { return }
        guard let ffmpeg = manager?.tool("ffmpeg"), let ffprobe = manager?.tool("ffprobe") else {
            problem = Converting.Failure.noFFmpeg.localizedDescription
            return
        }
        problem = nil
        let brand = BrandProfiles.shared.profile(UUID(uuidString: UserDefaults.standard.string(forKey: "deliveryCheckBrand") ?? ""))
        // (Items are found by id after each wait: the queue can change while a file is checked.)
        let queue = items.filter { all || $0.report == nil }.map { ($0, spec(of: $0)) }
        running = Task {
            defer { running = nil; save() }
            for (item, spec) in queue {
                guard !Task.isCancelled else { break }
                let id = item.id, file = item.file
                if items.count == 1 || current == nil { current = id }
                progress = 0
                var report: DeliveryCheck.Report?, failed: String?
                do {
                    var result = try await DeliveryCheck.run(file, spec: spec, ffmpeg: ffmpeg, ffprobe: ffprobe) { value, text in
                        Task { @MainActor in
                            self.progress = value
                            if !text.isEmpty { self.stage = text }
                        }
                    }
                    if let brand, !Task.isCancelled {
                        result.issues += await BrandCheck.run(file: file, profile: brand, duration: result.duration) { value in
                            Task { @MainActor in self.progress = value }
                        }
                        result.issues.sort { ($0.severity, $0.time ?? -1) < ($1.severity, $1.time ?? -1) }
                    }
                    if let approved = item.approved, !Task.isCancelled, let old = try? await DeliveryCheck.run(approved, spec: spec, ffmpeg: ffmpeg, ffprobe: ffprobe, progress: { _, _ in }) {
                        result.issues = DeliveryCheck.markNew(result.issues, approved: old) + DeliveryCheck.compare(result, approved: old)
                    }
                    report = result
                } catch is CancellationError {
                    break
                } catch {
                    failed = error.localizedDescription
                }
                // Stopped part way: what was measured isn't a whole report.
                guard !Task.isCancelled else { break }
                guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index].report = report
                items[index].failed = failed
                revision += 1
                save()
            }
        }
    }

    // MARK: - Kept between launches

    private struct SavedReport: Codable {
        var file: URL, spec: DeliveryCheck.Spec
        var duration: Double, fps: Double, width: Double, height: Double
        var facts: [[String]]
        var issues: [DeliveryCheck.Issue]
        var loudness: Double?, fileKey: String

        init(_ r: DeliveryCheck.Report) {
            file = r.file; spec = r.spec; duration = r.duration; fps = r.fps; width = r.size.width; height = r.size.height
            facts = r.facts.map { [$0.0, $0.1] }; issues = r.issues; loudness = r.loudness; fileKey = r.fileKey
        }

        var report: DeliveryCheck.Report {
            DeliveryCheck.Report(file: file, spec: spec, duration: duration, fps: fps, size: CGSize(width: width, height: height),
                                 facts: facts.map { ($0[0], $0[1]) }, issues: issues, loudness: loudness, fileKey: fileKey)
        }
    }

    private struct Saved: Codable {
        var file: URL
        var specID: String?
        var approved: URL?
        var failed: String?
        var report: SavedReport?
        var isCurrent = false
    }

    func save() {
        guard let url else { return }
        // The last ones, without a part-way check.
        let kept = items.suffix(Self.keep).map {
            Saved(file: $0.file, specID: $0.specID, approved: $0.approved, failed: $0.failed, report: $0.report.map(SavedReport.init), isCurrent: $0.id == current)
        }
        try? JSONEncoder().encode(Array(kept)).write(to: url, options: .atomic)
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        // Files that are gone stay out.
        items = saved.filter { FileManager.default.fileExists(atPath: $0.file.path) }.map {
            Item(file: $0.file, specID: $0.specID, report: $0.report?.report, failed: $0.failed, approved: $0.approved)
        }
        let currentFile = saved.first { $0.isCurrent }?.file
        current = (items.first { $0.file == currentFile } ?? items.first)?.id
    }
}
