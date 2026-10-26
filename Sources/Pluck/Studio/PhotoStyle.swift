import CoreML
import Foundation
import Observation

/// A ranking learned from the user's own picks: which photos of a moment they kept in a set of
/// Lightroom collections. Only the description is kept here; the model itself is a compiled
/// Core ML file next to the list in Application Support.
struct PhotoStyle: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var catalog: URL
    var collections: [Int]
    var trained: Date?
    /// Photos learned from, and photos left out because Lightroom had no preview of them.
    var photos = 0
    var skipped = 0
    /// The share of keepers shown on top (the top quarter of each moment), measured on collections
    /// the model didn't learn from. Nil until trained, or with only one collection.
    var covered: Double?
    /// The share of photos shown on top in that same measure.
    var shown: Double?
}

// MARK: - What a style learns from

extension PhotoStyle {
    /// The measures a style learns from, the same in training and in ranking: the photo's own
    /// signals, how it compares with the rest of its moment (`PhotoRanker.relativeFeatures`, plus eyes and
    /// face size), and where it sits in the moment (place, time to its neighbours, closest look-alike).
    /// Moments are in capture order. The feature print itself is left out (the spike found it adds little).
    static let features: [String] = [
        "sharpness", "faceSharpness", "faceCount", "faceSize", "faceQuality", "eyesOpen", "aesthetics", "utility", "blurDirection",
        "logShutter", "logIso", "focal",
        "rank_sharp", "diff_sharp", "ratio_sharp", "rank_aes", "diff_aes", "ratio_aes", "rank_faceQ", "diff_faceQ", "ratio_faceQ",
        "momSize", "momLogSize", "distBest",
        "momPos", "gapPrev", "gapNext", "nearest", "momFaceShare", "rank_eyes", "rank_faceSize",
    ]

    /// The features of each photo of a moment, by name; anything unknown is -1.
    static func featureRows(_ moment: [String], checks: [String: PhotoCheck]) -> [[String: Double]] {
        let relative = PhotoRanker.relativeFeatures(moment, checks: checks)
        let signals = moment.map { checks[$0]?.signals }
        let times = moment.map { checks[$0]?.taken }
        let faceShare = Double(signals.filter { ($0?.faceCount ?? 0) > 0 }.count) / Double(max(moment.count, 1))
        /// 0 = the best of the moment, 1 = the worst, among those that have the measure.
        func rank(_ value: (PhotoSignals) -> Double?) -> [Double?] {
            let values = signals.map { $0.flatMap(value) }
            let known = values.compactMap { $0 }
            return values.map { mine in mine.map { m in known.count > 1 ? Double(known.filter { $0 > m }.count) / Double(known.count - 1) : 0 } }
        }
        let eyes = rank(\.eyesOpen), faceSizes = rank { $0.faceCount > 0 ? $0.faceSize : nil }
        return moment.indices.map { index in
            let s = signals[index]
            var row = relative[index]
            // Where it sits in the moment: its place in the burst, the seconds to its neighbours, and the closest look-alike.
            row["momPos"] = moment.count > 1 ? Double(index) / Double(moment.count - 1) : 0
            if let now = times[index] {
                row["gapPrev"] = index > 0 ? times[index - 1].map { now.timeIntervalSince($0) } : 999
                row["gapNext"] = index < moment.count - 1 ? times[index + 1].map { $0.timeIntervalSince(now) } : 999
            }
            if let print = s?.print, !print.isEmpty {
                let others = moment.indices.filter { $0 != index }.compactMap { signals[$0]?.print }.filter { !$0.isEmpty }
                row["nearest"] = others.map { Double(PhotoSignals.distance(print, $0)) }.min() ?? 9
            }
            row["momFaceShare"] = faceShare
            row["rank_eyes"] = eyes[index]
            row["rank_faceSize"] = faceSizes[index]
            row["sharpness"] = s?.sharpness ?? checks[moment[index]]?.sharpness
            row["faceSharpness"] = s?.faceSharpness
            row["faceCount"] = s.map { Double($0.faceCount) }
            row["faceSize"] = s?.faceSize
            row["faceQuality"] = s?.faceQuality
            row["eyesOpen"] = s?.eyesOpen
            row["aesthetics"] = s?.aesthetics
            row["utility"] = s?.utility.map { $0 ? 1 : 0 }
            row["blurDirection"] = s?.blurDirection
            row["logShutter"] = s?.shutter.flatMap { $0 > 0 ? log2($0) : nil }
            row["logIso"] = s?.iso.flatMap { $0 > 0 ? log2($0) : nil }
            row["focal"] = s?.focal
            return Dictionary(uniqueKeysWithValues: features.map { name in (name, row[name].flatMap { $0.isFinite ? $0 : nil } ?? -1) })
        }
    }
}

// MARK: - Ranking with a style

extension PhotoRanker {
    /// Ranks by a trained model's keeper probability. If the model can't answer, the built-in ranking is used.
    init(model: MLModel) {
        self.init { moment, checks in
            guard !moment.isEmpty else { return [] }
            let rows = PhotoStyle.featureRows(moment, checks: checks)
            return Self.keeperProbabilities(model, rows: rows) ?? PhotoRanker.builtIn.scores(moment, checks: checks)
        }
    }

    /// The chosen style's ranking, or the built-in one when its model is missing.
    @MainActor
    init(style: PhotoStyle) {
        if let model = PhotoStyles.shared.model(for: style) { self.init(model: model) } else { self = .builtIn }
    }

    /// The probability of "kept" for each row, or nil when the model fails.
    static func keeperProbabilities(_ model: MLModel, rows: [[String: Double]]) -> [Double]? {
        let inputs = rows.compactMap { row in
            try? MLDictionaryFeatureProvider(dictionary: row.mapValues { MLFeatureValue(double: $0) })
        }
        guard inputs.count == rows.count, let name = model.modelDescription.predictedProbabilitiesName,
              let outputs = try? model.predictions(from: MLArrayBatchProvider(array: inputs), options: MLPredictionOptions()) else { return nil }
        return (0..<outputs.count).map { index in
            let probabilities = outputs.features(at: index).featureValue(for: name)?.dictionaryValue ?? [:]
            // Labels are 0 (dropped) and 1 (kept); the keys come back as Int64.
            return probabilities.first { "\($0.key)" == "1" }?.value.doubleValue ?? 0
        }
    }
}

// MARK: - The saved styles

/// The user's styles and which one ranks the Photo page, saved in Application Support/Pluck/Styles.
@MainActor
@Observable
final class PhotoStyles {
    static let shared = PhotoStyles()

    var styles: [PhotoStyle] = [] { didSet { save() } }
    /// The style that ranks moments; nil uses the built-in ranking.
    var chosen: UUID? { didSet { save() } }
    @ObservationIgnored private var models: [UUID: MLModel] = [:]

    private struct Saved: Codable {
        var styles: [PhotoStyle]
        var chosen: UUID?
    }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Styles")
    }

    nonisolated private static var file: URL { folder.appendingPathComponent("Styles.json") }

    /// Where a style's compiled model lives.
    nonisolated static func modelURL(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).mlmodelc") }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            styles = saved.styles
            chosen = saved.chosen
        }
    }

    var chosenStyle: PhotoStyle? { styles.first { $0.id == chosen } }

    /// The style's compiled model, loaded once; nil when it hasn't been trained.
    func model(for style: PhotoStyle) -> MLModel? {
        if let model = models[style.id] { return model }
        let url = Self.modelURL(for: style.id)
        guard FileManager.default.fileExists(atPath: url.path), let model = try? MLModel(contentsOf: url) else { return nil }
        models[style.id] = model
        return model
    }

    /// Adds a style or replaces the one with its id (after training, say).
    func update(_ style: PhotoStyle) {
        models[style.id] = nil
        if let index = styles.firstIndex(where: { $0.id == style.id }) { styles[index] = style } else { styles.append(style) }
    }

    /// Removes a style and its model.
    func remove(_ style: PhotoStyle) {
        models[style.id] = nil
        try? FileManager.default.removeItem(at: Self.modelURL(for: style.id))
        styles.removeAll { $0.id == style.id }
        if chosen == style.id { chosen = nil }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Saved(styles: styles, chosen: chosen)) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

// MARK: - The style's usual look

extension PhotoStyles {
    /// Saves the usual look of the style's keepers as a Pluck look named after the style, replacing the
    /// one an earlier call made. Returns false when the catalog can't be read or its keepers have no edits.
    /// The catalog is read off the main thread (twenty shoots take several seconds).
    @discardableResult
    func saveLook(for style: PhotoStyle, into target: PhotoCatalog? = nil) async -> Bool {
        let url = style.catalog, collections = style.collections
        let look = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            guard let catalog = try? LightroomCatalog(url: url) else { return [:] }
            let keepers = collections.flatMap { catalog.photos(in: $0) }.filter { $0.rating >= 1 }
            return LightroomCatalog.usualLook(keepers)
        }.value
        guard !look.isEmpty else { return false }
        let (adjust, _) = LightroomPresets.adjustments(look)
        (target ?? .shared).importPreset(named: style.name, adjust: adjust, source: "style:\(style.id.uuidString)", lightroom: look)
        return true
    }
}
