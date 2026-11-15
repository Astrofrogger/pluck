import Foundation

/// How one clip goes into the next: a dip to a colour, or both pictures at once (a dissolve, a
/// wipe, a push, a glitch…), drawn by one renderer in the viewer and the export
/// (`ProjectTransitions.blend`). Settings a kind doesn't use stay nil.
struct ProjectTransition: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        // Dissolves
        case dissolve, dipBlack, dipWhite, dipColour, additiveDissolve, nonAdditiveDissolve, lumaFade
        // Blur
        case blurDissolve, motionBlur, zoomBlur, spinBlur, focusPull
        // Wipes
        case wipe, centerWipe, bandWipe, clockWipe, edgeWipe, radialWipe, spiralWipe, venetianBlind, xWipe, barnDoor, checkerWipe, randomBlocks
        // Iris and shapes
        case irisOpen, irisClose, arrowIris, crossIris, diamondIris, eyeIris, hexagonIris, pentagonIris, squareIris, triangleIris
        case box, heart, star, triangleLeft, triangleRight
        // Slides and 3D
        case push, slide, reveal, split, whip, swipe, squeeze, cube, flip, pageCurl, door
        // Zoom and spin
        case zoomIn, zoomOut, pullIn, pullOut, crashZoom, spin, rotate, shake
        // Light
        case flash, exposure, glow, lightLeak, filmBurn, lensFlare, tunnelOfLight, filmStrip
        // Glitch and distortion
        case glitch, rgbSplit, pixelate, mosaic, ripple, swirl, wave, bulge, staticNoise

        /// Both pictures at once around the cut (a dip fades one out, then the other in).
        var overlaps: Bool { self != .dipBlack && self != .dipWhite }

        var group: Group {
            switch self {
            case .dissolve, .dipBlack, .dipWhite, .dipColour, .additiveDissolve, .nonAdditiveDissolve, .lumaFade: .dissolves
            case .blurDissolve, .motionBlur, .zoomBlur, .spinBlur, .focusPull: .blur
            case .wipe, .centerWipe, .bandWipe, .clockWipe, .edgeWipe, .radialWipe, .spiralWipe, .venetianBlind, .xWipe, .barnDoor,
                 .checkerWipe, .randomBlocks: .wipes
            case .irisOpen, .irisClose, .arrowIris, .crossIris, .diamondIris, .eyeIris, .hexagonIris, .pentagonIris, .squareIris,
                 .triangleIris, .box, .heart, .star, .triangleLeft, .triangleRight: .shapes
            case .push, .slide, .reveal, .split, .whip, .swipe, .squeeze, .cube, .flip, .pageCurl, .door: .slides
            case .zoomIn, .zoomOut, .pullIn, .pullOut, .crashZoom, .spin, .rotate, .shake: .camera
            case .flash, .exposure, .glow, .lightLeak, .filmBurn, .lensFlare, .tunnelOfLight, .filmStrip: .light
            case .glitch, .rgbSplit, .pixelate, .mosaic, .ripple, .swirl, .wave, .bulge, .staticNoise: .glitch
            }
        }

        /// The settings this kind reads (the Inspector shows only these).
        var settings: Set<Setting> {
            var s: Set<Setting> = [.easing]
            switch self {
            case .wipe, .bandWipe, .edgeWipe, .venetianBlind, .centerWipe, .barnDoor: s.formUnion([.direction, .softness])
            case .clockWipe, .radialWipe, .spiralWipe, .xWipe, .checkerWipe, .randomBlocks: s.insert(.softness)
            case .push, .slide, .reveal, .split, .squeeze, .cube, .flip, .pageCurl, .door, .filmStrip, .rotate: s.insert(.direction)
            case .whip, .swipe, .motionBlur: s.formUnion([.direction, .intensity])
            case .dipColour: s.insert(.colour)
            case .flash: s.formUnion([.colour, .intensity])
            case .lumaFade: s.insert(.softness)
            case .blurDissolve, .zoomBlur, .spinBlur, .focusPull, .pullIn, .pullOut, .crashZoom, .spin, .shake, .exposure, .glow,
                 .lightLeak, .filmBurn, .lensFlare, .tunnelOfLight, .glitch, .rgbSplit, .pixelate, .mosaic, .ripple, .swirl, .wave,
                 .bulge, .staticNoise: s.insert(.intensity)
            default: break
            }
            if group == .shapes { s.insert(.softness) }
            return s
        }

        /// Which way it goes when nothing's chosen.
        var defaultDirection: Direction {
            switch self {
            case .filmStrip: .up
            default: .left
            }
        }

        /// How strong it is when nothing's chosen (0–1).
        var defaultIntensity: Double { 0.5 }

        /// The edge's softness when nothing's chosen (0–1).
        var defaultSoftness: Double {
            switch self {
            case .wipe, .centerWipe, .barnDoor, .venetianBlind, .bandWipe, .checkerWipe, .randomBlocks: 0
            case .lumaFade: 0.5
            default: 0.05
            }
        }

        var defaultColour: TransitionColour {
            self == .flash ? .white : .black
        }

        /// Words a search finds it by, besides its name (English, as typed in the search field).
        var keywords: String {
            switch self {
            case .dissolve: "mix fade cross"
            case .dipBlack: "black fade"
            case .dipWhite: "white fade"
            case .dipColour: "color fade dip"
            case .additiveDissolve, .nonAdditiveDissolve: "mix fade bright"
            case .lumaFade: "luma brightness mix"
            case .blurDissolve, .focusPull: "blur focus soft defocus"
            case .motionBlur, .whip, .swipe: "motion blur fast pan swipe whip"
            case .zoomBlur, .pullIn, .pullOut, .crashZoom, .zoomIn, .zoomOut: "zoom push pull camera blur"
            case .spinBlur, .spin, .rotate: "spin rotate turn camera"
            case .wipe, .edgeWipe, .centerWipe, .bandWipe, .clockWipe, .radialWipe, .spiralWipe, .venetianBlind, .xWipe, .barnDoor,
                 .checkerWipe, .randomBlocks: "wipe mask reveal"
            case .irisOpen, .irisClose, .arrowIris, .crossIris, .diamondIris, .eyeIris, .hexagonIris, .pentagonIris,
                 .squareIris, .triangleIris, .box, .heart, .star, .triangleLeft, .triangleRight: "iris shape mask circle"
            case .push, .slide, .reveal, .split, .squeeze: "slide move push cover"
            case .cube, .flip, .pageCurl, .door: "3d cube flip page turn door fold"
            case .shake: "shake camera jolt"
            case .flash, .exposure, .glow, .lightLeak, .filmBurn, .lensFlare, .tunnelOfLight: "light flash leak burn flare glow"
            case .filmStrip: "film strip frame"
            case .glitch, .rgbSplit, .staticNoise: "glitch rgb digital noise vhs static"
            case .pixelate, .mosaic: "pixel mosaic blocks"
            case .ripple, .swirl, .wave, .bulge: "distort warp water twirl"
            default: ""
            }
        }

        /// The Resolve transition it goes to (Resolve's own name) and whether that one looks the same.
        var resolve: (name: String, category: String, exact: Bool) {
            switch self {
            case .dissolve: ("Cross Dissolve", "simple", true)
            case .dipBlack: ("Dip To Color Dissolve", "simple", true)
            case .dipWhite, .dipColour: ("Dip To Color Dissolve", "simple", false)
            case .additiveDissolve: ("Additive Dissolve", "simple", true)
            case .nonAdditiveDissolve: ("Non-Additive Dissolve", "simple", true)
            case .blurDissolve: ("Blur Dissolve", "simple", true)
            case .irisOpen: ("Oval Iris", "simple", true)
            case .arrowIris: ("Arrow Iris", "simple", true)
            case .crossIris: ("Cross Iris", "simple", true)
            case .diamondIris: ("Diamond Iris", "simple", true)
            case .eyeIris: ("Eye Iris", "simple", true)
            case .hexagonIris: ("Hexagon Iris", "simple", true)
            case .pentagonIris: ("Pentagon Iris", "simple", true)
            case .squareIris: ("Square Iris", "simple", true)
            case .triangleIris: ("Triangle Iris", "simple", true)
            case .box: ("Box", "simple", true)
            case .heart: ("Heart", "simple", true)
            case .star: ("Star", "simple", true)
            case .triangleLeft: ("Triangle Left", "simple", true)
            case .triangleRight: ("Triangle Right", "simple", true)
            case .barnDoor: ("Barn Door", "simple", true)
            case .push: ("Push", "simple", true)
            case .slide: ("Slide", "simple", true)
            case .split: ("Split", "simple", true)
            case .bandWipe: ("Band Wipe", "simple", true)
            case .centerWipe: ("Center Wipe", "simple", true)
            case .clockWipe: ("Clock Wipe", "simple", true)
            case .wipe, .edgeWipe: ("Edge Wipe", "simple", true)
            case .radialWipe: ("Radial Wipe", "simple", true)
            case .spiralWipe: ("Spiral Wipe", "simple", true)
            case .venetianBlind: ("Venetian Blind Wipe", "simple", true)
            case .xWipe: ("X Wipe", "simple", true)
            case .flash: ("Brightness Flash", "fusion", true)
            case .shake: ("Camera Shake", "fusion", true)
            case .crashZoom: ("Crash Zoom", "fusion", true)
            case .glitch: ("Glitch", "fusion", true)
            case .filmStrip: ("Film Strip", "fusion", true)
            case .tunnelOfLight: ("Tunnel of Light", "fusion", true)
            case .pullIn, .pullOut: ("Zoom In and Out", "fusion", true)
            case .irisClose: ("Oval Iris", "simple", false)
            case .zoomBlur, .zoomIn, .zoomOut: ("Zoom In and Out", "fusion", false)
            case .reveal, .squeeze, .whip, .swipe, .cube: ("Push", "simple", false)
            case .flip, .pageCurl, .door: ("Slide", "simple", false)
            case .checkerWipe, .randomBlocks: ("Venetian Blind Wipe", "simple", false)
            case .exposure, .glow, .lightLeak, .filmBurn, .lensFlare: ("Brightness Flash", "fusion", false)
            case .rgbSplit, .staticNoise, .pixelate, .mosaic: ("Glitch", "fusion", false)
            case .lumaFade, .motionBlur, .spinBlur, .focusPull, .spin, .rotate, .ripple, .swirl, .wave, .bulge: ("Cross Dissolve", "simple", false)
            }
        }

        /// The kind a Resolve transition comes back as (the exact ones; else nil).
        static func from(resolve name: String) -> Kind? {
            allCases.first { $0.resolve.exact && $0.resolve.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        /// Saved projects from before directions were a setting ("wipeLeft").
        static func legacy(_ raw: String) -> (Kind, Direction)? {
            for (prefix, kind) in [("wipe", Kind.wipe), ("push", .push), ("whip", .whip)] where raw.hasPrefix(prefix) {
                if let direction = Direction(rawValue: raw.dropFirst(prefix.count).lowercased()) { return (kind, direction) }
            }
            return nil
        }
    }

    enum Group: CaseIterable {
        case dissolves, blur, wipes, shapes, slides, camera, light, glitch

        var label: String {
            switch self {
            case .dissolves: String(localized: "Dissolves")
            case .blur: String(localized: "Blur")
            case .wipes: String(localized: "Wipes")
            case .shapes: String(localized: "Iris & Shapes")
            case .slides: String(localized: "Slides & 3D")
            case .camera: String(localized: "Zoom & Spin")
            case .light: String(localized: "Light")
            case .glitch: String(localized: "Glitch & Distort")
            }
        }

        var kinds: [Kind] { Kind.allCases.filter { $0.group == self } }
    }

    enum Setting: Hashable { case direction, colour, softness, intensity, easing }

    /// Which way the incoming picture (or the edge) moves.
    enum Direction: String, Codable, CaseIterable, Sendable { case left, right, up, down }

    enum Easing: String, Codable, CaseIterable, Sendable {
        case linear, easeIn, easeOut, easeInOut

        func apply(_ t: Double) -> Double {
            switch self {
            case .linear: t
            case .easeIn: t * t
            case .easeOut: 1 - (1 - t) * (1 - t)
            case .easeInOut: t * t * (3 - 2 * t)
            }
        }
    }

    /// The sound at the cut: both mixed across it, or cut at it.
    enum Sound: String, Codable, Sendable { case crossfade, cut }

    var kind: Kind
    var length: Double
    var direction: Direction?
    var colour: TransitionColour?
    var softness: Double?
    var intensity: Double?
    var easing: Easing?
    var sound: Sound?

    init(kind: Kind, length: Double, direction: Direction? = nil, colour: TransitionColour? = nil, softness: Double? = nil,
         intensity: Double? = nil, easing: Easing? = nil, sound: Sound? = nil) {
        self.kind = kind; self.length = length; self.direction = direction; self.colour = colour
        self.softness = softness; self.intensity = intensity; self.easing = easing; self.sound = sound
    }

    private enum CodingKeys: String, CodingKey { case kind, length, direction, colour, softness, intensity, easing, sound }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .kind)
        if let kind = Kind(rawValue: raw) {
            self.kind = kind
            direction = try? c.decodeIfPresent(Direction.self, forKey: .direction)
        } else if let (kind, way) = Kind.legacy(raw) {
            self.kind = kind
            direction = way
        } else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown transition \(raw)")
        }
        length = (try? c.decodeIfPresent(Double.self, forKey: .length)) ?? 1
        colour = try? c.decodeIfPresent(TransitionColour.self, forKey: .colour)
        softness = try? c.decodeIfPresent(Double.self, forKey: .softness)
        intensity = try? c.decodeIfPresent(Double.self, forKey: .intensity)
        easing = try? c.decodeIfPresent(Easing.self, forKey: .easing)
        sound = try? c.decodeIfPresent(Sound.self, forKey: .sound)
    }

    /// The same transition as another kind, keeping the length and sound (the rest is per kind).
    func with(kind: Kind) -> ProjectTransition {
        ProjectTransition(kind: kind, length: length, sound: sound)
    }

    // The settings as drawn (the kind's own when none is chosen).
    var way: Direction { direction ?? kind.defaultDirection }
    var tint: TransitionColour { colour ?? kind.defaultColour }
    var soft: Double { min(max(softness ?? kind.defaultSoftness, 0), 1) }
    var strength: Double { min(max(intensity ?? kind.defaultIntensity, 0), 1) }
    var curve: Easing { easing ?? .linear }

    var label: String { kind.label }
}

/// A transition's colour (a dip's, a flash's), as the video's numbers (0–1).
struct TransitionColour: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = TransitionColour(red: 0, green: 0, blue: 0)
    static let white = TransitionColour(red: 1, green: 1, blue: 1)
}

extension ProjectTransition.Kind {
    var label: String {
        switch self {
        case .dissolve: String(localized: "Cross Dissolve")
        case .dipBlack: String(localized: "Dip to Black")
        case .dipWhite: String(localized: "Dip to White")
        case .dipColour: String(localized: "Dip to Colour")
        case .additiveDissolve: String(localized: "Additive Dissolve")
        case .nonAdditiveDissolve: String(localized: "Non-Additive Dissolve")
        case .lumaFade: String(localized: "Luma Fade")
        case .blurDissolve: String(localized: "Blur Dissolve")
        case .motionBlur: String(localized: "Motion Blur")
        case .zoomBlur: String(localized: "Zoom Blur")
        case .spinBlur: String(localized: "Spin Blur")
        case .focusPull: String(localized: "Focus Pull")
        case .wipe: String(localized: "Wipe")
        case .centerWipe: String(localized: "Center Wipe")
        case .bandWipe: String(localized: "Band Wipe")
        case .clockWipe: String(localized: "Clock Wipe")
        case .edgeWipe: String(localized: "Edge Wipe")
        case .radialWipe: String(localized: "Radial Wipe")
        case .spiralWipe: String(localized: "Spiral Wipe")
        case .venetianBlind: String(localized: "Venetian Blind")
        case .xWipe: String(localized: "X Wipe")
        case .barnDoor: String(localized: "Barn Door")
        case .checkerWipe: String(localized: "Checker Wipe")
        case .randomBlocks: String(localized: "Random Blocks")
        case .irisOpen: String(localized: "Iris Open")
        case .irisClose: String(localized: "Iris Close")
        case .arrowIris: String(localized: "Arrow Iris")
        case .crossIris: String(localized: "Cross Iris")
        case .diamondIris: String(localized: "Diamond Iris")
        case .eyeIris: String(localized: "Eye Iris")
        case .hexagonIris: String(localized: "Hexagon Iris")
        case .pentagonIris: String(localized: "Pentagon Iris")
        case .squareIris: String(localized: "Square Iris")
        case .triangleIris: String(localized: "Triangle Iris")
        case .box: String(localized: "Box")
        case .heart: String(localized: "Heart")
        case .star: String(localized: "Star")
        case .triangleLeft: String(localized: "Triangle Left")
        case .triangleRight: String(localized: "Triangle Right")
        case .push: String(localized: "Push")
        case .slide: String(localized: "Slide")
        case .reveal: String(localized: "Reveal")
        case .split: String(localized: "Split")
        case .whip: String(localized: "Whip Pan")
        case .swipe: String(localized: "Swipe")
        case .squeeze: String(localized: "Squeeze")
        case .cube: String(localized: "Cube")
        case .flip: String(localized: "Flip")
        case .pageCurl: String(localized: "Page Curl")
        case .door: String(localized: "Door")
        case .zoomIn: String(localized: "Zoom In")
        case .zoomOut: String(localized: "Zoom Out")
        case .pullIn: String(localized: "Pull In")
        case .pullOut: String(localized: "Pull Out")
        case .crashZoom: String(localized: "Crash Zoom")
        case .spin: String(localized: "Spin")
        case .rotate: String(localized: "Rotate")
        case .shake: String(localized: "Shake")
        case .flash: String(localized: "Flash")
        case .exposure: String(localized: "Exposure")
        case .glow: String(localized: "Glow")
        case .lightLeak: String(localized: "Light Leak")
        case .filmBurn: String(localized: "Film Burn")
        case .lensFlare: String(localized: "Lens Flare")
        case .tunnelOfLight: String(localized: "Tunnel of Light")
        case .filmStrip: String(localized: "Film Strip")
        case .glitch: String(localized: "Glitch")
        case .rgbSplit: String(localized: "RGB Split")
        case .pixelate: String(localized: "Pixelate")
        case .mosaic: String(localized: "Mosaic")
        case .ripple: String(localized: "Ripple")
        case .swirl: String(localized: "Swirl")
        case .wave: String(localized: "Wave")
        case .bulge: String(localized: "Bulge")
        case .staticNoise: String(localized: "Static")
        }
    }
}
