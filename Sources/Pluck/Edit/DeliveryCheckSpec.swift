import Foundation

extension DeliveryCheck {
    /// What a delivery has to be: picture, sound and loudness. The four destinations are the
    /// built-in presets; anyone can save their own (kept in UserDefaults).
    struct Spec: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        /// Width ÷ height, if it has to be one shape.
        var aspect: Double?
        /// Exactly this size, if set.
        var width: Int?
        var height: Int?
        /// At least this many pixels along the long side (a warning, not a problem).
        var minLongSide: Int?
        /// Any of these (fps); empty: any.
        var frameRates: [Double] = []
        /// Any of these ffprobe codec names (h264, hevc, prores…); empty: any.
        var codecs: [String] = []
        /// Video bitrate range, Mb/s.
        var minBitrate: Double?
        var maxBitrate: Double?
        /// ffprobe colour tags (bt709, bt2020, smpte2084…); nil: any.
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var sampleRate: Int?
        var channels: Int?
        /// Integrated loudness (LUFS), how far off is fine (LU), the highest true peak (dBTP).
        var loudness: Double?
        var loudnessTolerance = 2.0
        var truePeak = -1.0
        /// Broadcast: anything off is a problem (it gets rejected), not something to check.
        var strict = false
        /// The area text should stay in (normalized, origin bottom left).
        var safeArea = CGRect(x: 0.035, y: 0.035, width: 0.93, height: 0.93)

        /// The shapes that pass: Social takes whatever the file is meant for (9:16, 1:1, 4:5, 16:9), the rest their one shape.
        // shortcut: only the Social preset follows the file; a saved copy of it keeps its one shape.
        var allowedAspects: [Double] {
            id == Destination.social.rawValue ? [9.0 / 16, 1, 4.0 / 5, 16.0 / 9] : aspect.map { [$0] } ?? []
        }

        var builtIn: Bool { Destination(rawValue: id) != nil }
        /// The preset's own (translated) name, else the saved one.
        var title: String { Destination(rawValue: id)?.label ?? name }
        var shortTitle: String { Destination(rawValue: id)?.shortLabel ?? name }

        /// "16:9", "9:16", or "1.85:1".
        static func aspectText(_ aspect: Double) -> String {
            for (w, h) in [(16, 9), (9, 16), (1, 1), (4, 5), (4, 3), (21, 9)] where abs(aspect - Double(w) / Double(h)) < 0.01 { return "\(w):\(h)" }
            return String(format: "%.2f:1", aspect)
        }
    }

    static let specsKey = "deliveryCheckSpecs"

    /// The presets, then the ones saved here.
    static var specs: [Spec] { Destination.allCases.map(\.spec) + userSpecs }

    static var userSpecs: [Spec] {
        get { (UserDefaults.standard.data(forKey: specsKey)).flatMap { try? JSONDecoder().decode([Spec].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: specsKey) }
    }

    /// The spec a brand profile's "delivery spec" names: its id, or (older free text) its name; nil if none fits.
    static func specID(matching text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else { return nil }
        return specs.first { [$0.id, $0.title, $0.name, $0.shortTitle].contains { $0.lowercased() == text } }?.id
    }

    static func spec(id: String) -> Spec { specs.first { $0.id == id } ?? Destination.online.spec }

    /// Saves a new or changed spec of one's own (a preset is saved as a copy).
    @discardableResult static func save(_ spec: Spec) -> Spec {
        var spec = spec
        if spec.builtIn { spec.id = UUID().uuidString }
        var all = userSpecs
        if let index = all.firstIndex(where: { $0.id == spec.id }) { all[index] = spec } else { all.append(spec) }
        userSpecs = all
        return spec
    }

    static func delete(_ spec: Spec) { userSpecs.removeAll { $0.id == spec.id } }
}

extension DeliveryCheck.Destination {
    /// The destination as a spec: what Delivery Check has always checked for it, plus colour for broadcast.
    var spec: DeliveryCheck.Spec {
        var spec = DeliveryCheck.Spec(id: rawValue, name: shortLabel, aspect: aspect, minLongSide: aspect == nil ? nil : self == .social ? 1080 : 1920)
        if let loudness {
            spec.loudness = loudness.target
            spec.loudnessTolerance = loudness.tolerance
            spec.truePeak = loudness.peak
        }
        spec.safeArea = safeArea
        switch self {
        case .broadcastEU:
            spec.frameRates = [25, 50]
        case .broadcastUS:
            spec.frameRates = [29.97, 59.94]
        default:
            break
        }
        if self == .broadcastEU || self == .broadcastUS {
            spec.strict = true
            spec.sampleRate = 48_000
            spec.primaries = "bt709"
            spec.transfer = "bt709"
            spec.matrix = "bt709"
        }
        return spec
    }
}
