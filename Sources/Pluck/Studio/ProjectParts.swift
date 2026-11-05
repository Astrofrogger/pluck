import Foundation

/// A lane above or below the main line of clips: pictures laid over it (B-roll, a logo) or
/// sound beside it (a voice-over, the sound taken off a clip). Its clips sit where they're put
/// (`at`), not one after another.
struct ProjectTrack: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case video, audio }

    var id = UUID()
    var kind: Kind
    var name: String?
    var muted = false
    var hidden = false
    var locked = false
    var items: [ProjectClip] = []

    init(kind: Kind, name: String? = nil) {
        self.kind = kind
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        id = value(.id, UUID()); kind = value(.kind, .video); name = value(.name, nil as String?)
        muted = value(.muted, false); hidden = value(.hidden, false); locked = value(.locked, false)
        items = ((try? c.decodeIfPresent([ProjectLenient<ProjectClip>].self, forKey: .items)) ?? nil)?.compactMap(\.value) ?? []
    }
}

/// How one clip goes into the next: a dip to a colour, or both pictures at once (a dissolve, a
/// wipe, a push…), drawn the same in the viewer and the export (`ProjectTransitions`).
struct ProjectTransition: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case dissolve, dipBlack, dipWhite
        case wipeLeft, wipeRight, wipeUp, wipeDown, irisOpen, irisClose
        case pushLeft, pushRight, pushUp, pushDown, whipLeft, whipRight
        case zoomIn, zoomOut, blurDissolve

        /// Both pictures at once around the cut (a dip fades one out, then the other in).
        var overlaps: Bool { self != .dipBlack && self != .dipWhite }

        var group: Group {
            switch self {
            case .dissolve, .dipBlack, .dipWhite: .dissolves
            case .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .irisOpen, .irisClose: .wipes
            case .pushLeft, .pushRight, .pushUp, .pushDown, .whipLeft, .whipRight: .slides
            case .zoomIn, .zoomOut, .blurDissolve: .zoomAndBlur
            }
        }
    }

    enum Group: CaseIterable {
        case dissolves, wipes, slides, zoomAndBlur

        var label: String {
            switch self {
            case .dissolves: String(localized: "Dissolves")
            case .wipes: String(localized: "Wipes")
            case .slides: String(localized: "Slides")
            case .zoomAndBlur: String(localized: "Zoom & Blur")
            }
        }

        var kinds: [Kind] { Kind.allCases.filter { $0.group == self } }
    }

    var kind: Kind
    var length: Double

    var label: String {
        switch kind {
        case .dissolve: String(localized: "Cross Dissolve")
        case .dipBlack: String(localized: "Dip to Black")
        case .dipWhite: String(localized: "Dip to White")
        case .wipeLeft: String(localized: "Wipe Left")
        case .wipeRight: String(localized: "Wipe Right")
        case .wipeUp: String(localized: "Wipe Up")
        case .wipeDown: String(localized: "Wipe Down")
        case .irisOpen: String(localized: "Iris Open")
        case .irisClose: String(localized: "Iris Close")
        case .pushLeft: String(localized: "Push Left")
        case .pushRight: String(localized: "Push Right")
        case .pushUp: String(localized: "Push Up")
        case .pushDown: String(localized: "Push Down")
        case .whipLeft: String(localized: "Whip Pan Left")
        case .whipRight: String(localized: "Whip Pan Right")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        case .blurDissolve: String(localized: "Blur Dissolve")
        }
    }
}

/// A mark on the timeline made by hand: a moment, or a stretch, with a name and a colour.
struct ProjectMarker: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Timeline seconds.
    var time: Double
    var length: Double?
    var title: String = ""
    var color: Color = .blue

    enum Color: String, Codable, CaseIterable { case blue, green, yellow, red, purple }

    init(time: Double, title: String = "", color: Color = .blue) {
        self.time = time; self.title = title; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        time = (try? c.decodeIfPresent(Double.self, forKey: .time)) ?? 0
        length = try? c.decodeIfPresent(Double.self, forKey: .length)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        color = (try? c.decodeIfPresent(Color.self, forKey: .color)) ?? .blue
    }
}

/// One item of a list that may not read (it's then nil, and the rest still do).
struct ProjectLenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
