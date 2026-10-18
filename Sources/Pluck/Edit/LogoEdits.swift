import CryptoKit
import Foundation

/// What someone changed in a designed animation: its feel, which idea, the hero's move, and per
/// part when it comes in, how long it takes, where from, how it moves and how it eases. Saved
/// with the logo (by its contents), so the same logo opens with the same design.
struct LogoDesignEdits: Codable, Equatable, Sendable {
    var feel: LogoProfile.Personality?
    var seed = 0
    var hero: LogoAnimation.HeroMove?
    var parts: [Int: PartEdit] = [:]

    struct PartEdit: Codable, Equatable, Sendable {
        /// Seconds later (negative: earlier).
        var delay = 0.0
        /// Its moves this many times as long.
        var length = 1.0
        var from: Direction?
        var motion: Motion?
        var ease: Ease?

        var isEmpty: Bool { self == PartEdit() }
    }

    enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
        case left, right, top, bottom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .left: String(localized: "Left")
            case .right: String(localized: "Right")
            case .top: String(localized: "Top")
            case .bottom: String(localized: "Bottom")
            }
        }
    }

    /// How a part other than the hero comes in, instead of as designed.
    enum Motion: String, Codable, CaseIterable, Identifiable, Sendable {
        case fade, rise, pop, slide, grow
        var id: String { rawValue }
        var label: String {
            switch self {
            case .fade: String(localized: "Fade")
            case .rise: String(localized: "Rise")
            case .pop: String(localized: "Pop")
            case .slide: String(localized: "Slide")
            case .grow: String(localized: "Grow")
            }
        }
        var help: String {
            switch self {
            case .fade: String(localized: "Fades in where it is")
            case .rise: String(localized: "Rises from behind the line it stands on")
            case .pop: String(localized: "Springs in from small")
            case .slide: String(localized: "Slides into view inside its own space")
            case .grow: String(localized: "Grows up from its foot")
            }
        }
    }

    enum Ease: String, Codable, CaseIterable, Identifiable, Sendable {
        case smooth, snappy, springy
        var id: String { rawValue }
        var label: String {
            switch self {
            case .smooth: String(localized: "Smooth")
            case .snappy: String(localized: "Snappy")
            case .springy: String(localized: "Springy")
            }
        }
        var help: String {
            switch self {
            case .smooth: String(localized: "A long, gentle ease into place")
            case .snappy: String(localized: "Quick off the mark, a crisp stop")
            case .springy: String(localized: "Past its place and back, like a spring")
            }
        }
    }
}

extension LogoAnimation {
    /// The design with someone's changes: the idea, feel and hero move they chose, then each
    /// part's changes, checked again so its last frame is still the logo.
    func design(edits: LogoDesignEdits, pace: Double = 1) -> Design? {
        guard var design = design(seed: edits.seed, personality: edits.feel, hero: edits.hero, pace: pace) else { return nil }
        guard edits.parts.values.contains(where: { !$0.isEmpty }) else { return design }
        var spec = design.spec
        // (In a fixed order, so the same edits always give the same animation.)
        for (index, edit) in edits.parts.sorted(by: { $0.key < $1.key }) where !edit.isEmpty && elements.indices.contains(index) {
            spec = apply(edit, to: index, in: spec)
        }
        spec = settle(spec)
        design.spec = spec
        design.valid = finalFrameMatches(spec)
        return design
    }

    /// When a part starts and ends in a spec.
    func span(of index: Int, in spec: MotionSpec) -> ClosedRange<Double>? {
        let tracks = spec.tracks.filter { $0.part.index == index }
        guard !tracks.isEmpty else { return nil }
        let starts = tracks.flatMap { track in track.keys.values.compactMap { $0.first?.time } + [track.appears].compactMap { $0 } }
        let start = starts.min() ?? 0
        let end = max(tracks.map(\.end).max() ?? start, start)
        return start...end
    }

    private func apply(_ edit: LogoDesignEdits.PartEdit, to index: Int, in spec: MotionSpec) -> MotionSpec {
        var spec = spec
        guard let span = span(of: index, in: spec) else { return spec }
        let start = span.lowerBound, length = max(span.upperBound - span.lowerBound, 0.35)
        let box = elements[index].box
        var tracks = spec.tracks.filter { $0.part.index == index }

        // Another motion: its tracks made again.
        if let motion = edit.motion {
            var t = MotionSpec.Track(part: .init(index: index), appears: start)
            let end = start + length
            switch motion {
            case .fade:
                t.move(.opacity, from: 0, to: 1, start: start, end: end, ease: .outCubic)
            case .rise:
                t.clip = .aboveBaseline
                t.move(.translateY, from: box.height * 0.9, to: 0, start: start, end: end, ease: .outCubic)
                t.move(.opacity, from: 0, to: 1, start: start, end: start + length * 0.3, ease: .linear)
            case .pop:
                t.move(.scale, from: 0.5, to: 1, start: start, end: end, ease: .outBack)
                t.move(.opacity, from: 0, to: 1, start: start, end: start + length * 0.35, ease: .outCubic)
            case .slide:
                t.clip = .region(box.insetBy(dx: -1, dy: -1))
                t.move(.translateX, from: -box.width, to: 0, start: start, end: end, ease: .outCubic)
            case .grow:
                t.anchor = CGPoint(x: 0.5, y: 1)
                t.move(.scaleY, from: 0.02, to: 1, start: start, end: end, ease: .outCubic)
                t.move(.opacity, from: 0, to: 1, start: start, end: start + length * 0.25, ease: .outCubic)
            }
            tracks = [t]
        }

        // From another side: its move across replaced.
        if let from = edit.from {
            let distance = max(box.width, box.height) * 0.8
            let (dx, dy): (Double, Double) = switch from {
            case .left: (-distance, 0)
            case .right: (distance, 0)
            case .top: (0, -distance)
            case .bottom: (0, distance)
            }
            for n in tracks.indices {
                tracks[n].move(.translateX, from: dx, to: 0, start: start, end: start + length, ease: .outCubic)
                tracks[n].move(.translateY, from: dy, to: 0, start: start, end: start + length, ease: .outCubic)
                // Rising from behind a line doesn't go with coming from a side.
                if tracks[n].clip == .aboveBaseline { tracks[n].clip = nil }
            }
        }

        // Another ease for all its moves (fading stays as it is).
        if let ease = edit.ease {
            for n in tracks.indices {
                for (property, keys) in tracks[n].keys where property != .opacity && property != .strokeOpacity {
                    let springy: MotionSpec.Ease = [.scale, .scaleX, .scaleY, .stretch].contains(property) ? .spring : .outBack
                    let chosen: MotionSpec.Ease = switch ease {
                    case .smooth: .calm
                    case .snappy: .bold
                    case .springy: springy
                    }
                    tracks[n].keys[property] = keys.enumerated().map { k, key in
                        var key = key
                        if k > 0 { key.ease = chosen }
                        return key
                    }
                }
            }
        }

        // Earlier or later, quicker or slower (never before the start).
        let delay = max(edit.delay, -start)
        if delay != 0 || edit.length != 1 {
            func time(_ t: Double) -> Double { start + (t - start) * edit.length + delay }
            for n in tracks.indices {
                tracks[n].appears = tracks[n].appears.map(time)
                for (property, keys) in tracks[n].keys {
                    tracks[n].keys[property] = keys.map { var key = $0; key.time = time(key.time); return key }
                }
            }
        }

        // In the same place in the drawing order (a plate stays under its letters).
        let places = spec.tracks.indices.filter { spec.tracks[$0].part.index == index }
        guard let first = places.first else { return spec }
        for place in places.reversed() { spec.tracks.remove(at: place) }
        spec.tracks.insert(contentsOf: tracks, at: first)
        return spec
    }
}

/// Where edits are kept: Application Support, one small file per logo, named for its contents.
enum LogoDesignStore {
    private static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pluck").appendingPathComponent("Logo Designs")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The logo's file by its contents (renamed or moved, it's still the same logo).
    static func key(for logo: URL) -> String? {
        guard let data = try? Data(contentsOf: logo, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func load(for logo: URL) -> LogoDesignEdits? {
        guard let folder, let key = key(for: logo),
              let data = try? Data(contentsOf: folder.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(LogoDesignEdits.self, from: data)
    }

    static func save(_ edits: LogoDesignEdits, for logo: URL) {
        guard let folder, let key = key(for: logo) else { return }
        let file = folder.appendingPathComponent(key + ".json")
        if edits == LogoDesignEdits() {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONEncoder().encode(edits) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
