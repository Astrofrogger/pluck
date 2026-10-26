import CoreGraphics
import CoreML
import CreateML
import Foundation
import TabularData

/// Trains a style from Lightroom collections (keeper = rated 1 or more) and measures it honestly: on
/// collections it didn't learn from, how many keepers land in the top quarter of their moment.
/// Works on Lightroom's 750 px previews, read-only; a photo with no preview is skipped and counted.
enum PhotoStyleTrainer {
    enum Failure: Error {
        /// The catalog can't be opened (moved, or not a catalog).
        case catalogUnreadable
        /// Learning needs both kept and not-kept photos with previews.
        case needsKeepersAndDrops
    }

    /// The preview size the signals are measured on.
    static let previewSize = 750
    /// The most held-out rounds when measuring.
    static let folds = 5

    /// One photo ready to learn from.
    private struct Sample {
        var key: String
        var collection: Int
        var kept: Bool
        var check: PhotoCheck
    }

    /// Trains `style` on its collections, saves the compiled model and returns the style with its
    /// numbers filled in. Runs at utility priority off the main actor; cancelling the calling task stops it.
    /// `iterations` is the number of boosted trees (fewer is faster and rougher).
    static func train(_ style: PhotoStyle, iterations: Int = 300, progress: @escaping @Sendable (Double) -> Void) async throws -> PhotoStyle {
        let work = Task.detached(priority: .utility) { try await run(style, iterations: iterations, progress: progress) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func run(_ style: PhotoStyle, iterations: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> PhotoStyle {
        guard let catalog = try? LightroomCatalog(url: style.catalog) else { throw Failure.catalogUnreadable }
        progress(0)

        // Each photo once, in the first chosen collection that has it.
        var seen = Set<Int>()
        var wanted: [(collection: Int, photo: LightroomCatalog.Photo)] = []
        for collection in style.collections {
            for photo in catalog.photos(in: collection) where seen.insert(photo.id).inserted { wanted.append((collection, photo)) }
        }

        // Signals, from the cache or measured on the preview, several at a time.
        let cache = signalsFolder(for: style.catalog)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let first = wanted.first { _ = catalog.preview(of: first.photo, longSide: previewSize) } // copies previews.db once, before the rush
        var measured: [Int: PhotoSignals] = [:]
        let chunk = 8 * measuringWidth
        for first in stride(from: 0, to: wanted.count, by: chunk) {
            try Task.checkCancellation()
            let photos = wanted[first..<min(first + chunk, wanted.count)].map(\.photo)
            for (photo, signals) in zip(photos, await measure(photos, catalog: catalog, cache: cache)) { measured[photo.id] = signals }
            progress(0.8 * Double(first + photos.count) / Double(wanted.count))
        }
        try Task.checkCancellation()

        let samples = wanted.compactMap { item -> Sample? in
            guard let signals = measured[item.photo.id] else { return nil }
            let check = PhotoCheck(sharpness: signals.sharpness ?? 0, faces: [], eyesClosed: (signals.eyesOpen ?? 1) < 0.16,
                                   taken: item.photo.captureTime, signals: signals)
            return Sample(key: "lr:\(item.photo.id)", collection: item.collection, kept: item.photo.rating >= 1, check: check)
        }
        guard samples.contains(where: \.kept), samples.contains(where: { !$0.kept }) else { throw Failure.needsKeepersAndDrops }

        // Moments per collection, and every photo's features within its moment.
        let checks = Dictionary(samples.map { ($0.key, $0.check) }, uniquingKeysWith: { a, _ in a })
        let kept = Dictionary(samples.map { ($0.key, $0.kept) }, uniquingKeysWith: { a, _ in a })
        var moments: [Int: [[String]]] = [:]
        for collection in Set(samples.map(\.collection)) {
            let keys = samples.filter { $0.collection == collection }.map(\.key)
            moments[collection] = PhotoMoments.group(keys, checks: checks)
        }
        var rows: [String: [String: Double]] = [:]
        for moment in moments.values.joined() {
            for (key, row) in zip(moment, PhotoStyle.featureRows(moment, checks: checks)) { rows[key] = row }
        }

        // Measure on held-out collections (biggest first, dealt round the folds), then learn from them all.
        func photos(of collection: Int) -> [String] { moments[collection]?.flatMap { $0 } ?? [] }
        let order = moments.keys.sorted { (photos(of: $0).count, $1) > (photos(of: $1).count, $0) }
        let foldCount = min(folds, order.count)
        var keepers = 0, keepersOnTop = 0, measuredPhotos = 0, onTop = 0
        if foldCount >= 2 {
            for fold in 0..<foldCount {
                try Task.checkCancellation()
                let held = Set(order.enumerated().filter { $0.offset % foldCount == fold }.map(\.element))
                let learn = order.filter { !held.contains($0) }.flatMap(photos(of:))
                if let model = try? fit(learn, rows: rows, kept: kept, iterations: iterations) {
                    let ranker = PhotoRanker(model: model)
                    for moment in held.flatMap({ moments[$0] ?? [] }) {
                        let top = PhotoMoments.split(moment, scores: ranker.scores(moment, checks: checks)).top
                        keepers += moment.filter { kept[$0] == true }.count
                        keepersOnTop += top.filter { kept[$0] == true }.count
                        measuredPhotos += moment.count
                        onTop += top.count
                    }
                }
                progress(0.8 + 0.15 * Double(fold + 1) / Double(foldCount))
            }
        }
        try Task.checkCancellation()
        let all = order.flatMap(photos(of:))
        guard let final = try fitClassifier(all, rows: rows, kept: kept, iterations: iterations) else { throw Failure.needsKeepersAndDrops }
        try await save(final, for: style.id)
        progress(1)

        var trained = style
        trained.trained = Date()
        trained.photos = samples.count
        trained.skipped = wanted.count - samples.count
        trained.covered = keepers > 0 ? Double(keepersOnTop) / Double(keepers) : nil
        trained.shown = measuredPhotos > 0 ? Double(onTop) / Double(measuredPhotos) : nil
        return trained
    }

    // MARK: Signals

    /// Where measured signals are kept: one small file per catalog photo, so a second training is quick.
    static func signalsFolder(for catalog: URL) -> URL {
        LightroomCatalog.cacheFolder(for: catalog).appendingPathComponent("Signals-1")
    }

    /// How many photos are measured at once. Vision deadlocks with too many at a time (its aesthetics
    /// request waits for room its own callers hold: 18 hung, 10 ran fine), so this stays at 6 or under:
    /// the Photo page's checks and search index may each be running one more at the same time.
    static let measuringWidth = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// Measures a batch side by side on GCD's threads: Vision blocks while it works, which would starve
    /// Swift's own small pool of threads.
    private static func measure(_ photos: [LightroomCatalog.Photo], catalog: LightroomCatalog, cache: URL) async -> [PhotoSignals?] {
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var values: [PhotoSignals?]
            init(_ count: Int) { values = Array(repeating: nil, count: count) }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let results = Results(photos.count)
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = measuringWidth
                queue.qualityOfService = .utility
                for index in photos.indices {
                    queue.addOperation {
                        let signals = autoreleasepool { signals(of: photos[index], catalog: catalog, cache: cache) }
                        results.lock.withLock { results.values[index] = signals }
                    }
                }
                queue.waitUntilAllOperationsAreFinished()
                continuation.resume(returning: results.values)
            }
        }
    }

    private static func signals(of photo: LightroomCatalog.Photo, catalog: LightroomCatalog, cache: URL) -> PhotoSignals? {
        let file = cache.appendingPathComponent("\(photo.id).plist")
        if let data = try? Data(contentsOf: file), let saved = try? PropertyListDecoder().decode(PhotoSignals.self, from: data) { return saved }
        guard let image = catalog.preview(of: photo, longSide: previewSize) else { return nil }
        var signals = PhotoSignals.measure(image, exif: nil)
        // Previews carry no EXIF; the catalog has it.
        signals.shutter = photo.shutter
        signals.iso = photo.iso
        signals.focal = photo.focalLength
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try? encoder.encode(signals).write(to: file, options: .atomic)
        return signals
    }

    // MARK: Learning

    private static func fit(_ keys: [String], rows: [String: [String: Double]], kept: [String: Bool], iterations: Int) throws -> MLModel? {
        try fitClassifier(keys, rows: rows, kept: kept, iterations: iterations)?.model
    }

    /// Boosted trees on the features; nil when the photos aren't a mix of kept and not.
    private static func fitClassifier(_ keys: [String], rows: [String: [String: Double]], kept: [String: Bool], iterations: Int) throws -> MLBoostedTreeClassifier? {
        let labels = keys.map { kept[$0] == true ? 1 : 0 }
        guard labels.contains(1), labels.contains(0) else { return nil }
        var table = DataFrame()
        table.append(column: Column(name: "keeper", contents: labels))
        for name in PhotoStyle.features { table.append(column: Column(name: name, contents: keys.map { rows[$0]?[name] ?? -1 })) }
        let parameters = MLBoostedTreeClassifier.ModelParameters(validation: .none, maxDepth: 6, maxIterations: iterations, minLossReduction: 0,
                                                                 minChildWeight: 0.1, randomSeed: 7, stepSize: 0.1, earlyStoppingRounds: nil,
                                                                 rowSubsample: 0.8, columnSubsample: 0.8)
        return try MLBoostedTreeClassifier(trainingData: table, targetColumn: "keeper",
                                           featureColumns: PhotoStyle.features, parameters: parameters)
    }

    /// Writes and compiles the model into the styles folder, replacing an earlier one.
    private static func save(_ classifier: MLBoostedTreeClassifier, for id: UUID) async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("pluck-style-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("Style.mlmodel")
        try classifier.write(to: source)
        let compiled = try await MLModel.compileModel(at: source)
        defer { try? fm.removeItem(at: compiled) }
        try fm.createDirectory(at: PhotoStyles.folder, withIntermediateDirectories: true)
        let destination = PhotoStyles.modelURL(for: id)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: compiled, to: destination)
    }
}
