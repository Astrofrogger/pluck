import CoreGraphics
import Foundation

/// A logo animation as data: for each part of the logo, how its look changes over time. The
/// classic styles are built as specs from the logo's parts; the procedural ones (Assemble,
/// Liquid and the expressive styles) keep their own code. Codable, so a spec can be saved and
/// edited.
struct MotionSpec: Codable, Equatable, Sendable {
    var tracks: [Track]
    /// A soft-edged reveal over the whole logo (Soft Wipe).
    var wipe: Wipe?

    /// A part of the logo (for now its place in the logo's parts, which analysis keeps stable
    /// for the same file).
    struct PartID: Codable, Hashable, Sendable {
        var index: Int
    }

    /// What can change. Translation is in logo pixels (y down); rotation in radians,
    /// anticlockwise on screen; focus 0 is sharp, 1 the softest; trim is how much of the outline
    /// is drawn.
    enum Property: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
        case opacity, translateX, translateY, scale, scaleX, scaleY, rotation
        /// Squash and stretch: taller by this factor and narrower by the same, so the area stays.
        case stretch
        case focus
        case strokeTrim, strokeOpacity

        var rest: Double {
            switch self {
            case .opacity, .scale, .scaleX, .scaleY, .stretch: 1
            case .translateX, .translateY, .rotation, .focus, .strokeTrim, .strokeOpacity: 0
            }
        }
    }

    /// How a move arrives at a keyframe.
    enum Ease: Codable, Equatable, Sendable {
        case linear, hold
        case outCubic, outQuint, inOutCubic, outExpo, outBack, spring
        /// Ease-out for calm, corporate marks.
        case calm
        /// A long deceleration for premium marks.
        case premium
        /// The expressive curve for bold, technical marks.
        case bold
        case bezier(Double, Double, Double, Double)

        private static let named: [String: Ease] = [
            "linear": .linear, "hold": .hold, "outCubic": .outCubic, "outQuint": .outQuint, "inOutCubic": .inOutCubic,
            "outExpo": .outExpo, "outBack": .outBack, "spring": .spring, "calm": .calm, "premium": .premium, "bold": .bold,
        ]

        /// In JSON: its name, or the four control values of a Bézier.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let name = try? container.decode(String.self) {
                guard let ease = Self.named[name] else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown ease \(name)")
                }
                self = ease
            } else {
                let values = try container.decode([Double].self)
                guard values.count == 4 else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "A Bézier has four values") }
                self = .bezier(values[0], values[1], values[2], values[3])
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if case let .bezier(x1, y1, x2, y2) = self {
                try container.encode([x1, y1, x2, y2])
            } else {
                try container.encode(Self.named.first { $0.value == self }!.key)
            }
        }

        func callAsFunction(_ x: Double) -> Double {
            switch self {
            case .linear: x
            case .hold: x >= 1 ? 1 : 0
            case .outCubic: Easing.outCubic(x)
            case .outQuint: Easing.outQuint(x)
            case .inOutCubic: Easing.inOutCubic(x)
            case .outExpo: Easing.outExpo(x)
            case .outBack: Easing.outBack(x)
            case .spring: Easing.spring(x)
            case .calm: Easing.bezier(0, 0, 0.2, 1, x)
            case .premium: Easing.bezier(0.05, 0.7, 0.1, 1, x)
            case .bold: Easing.bezier(0.9, 0, 0.1, 1, x)
            case let .bezier(x1, y1, x2, y2): Easing.bezier(x1, y1, x2, y2, x)
            }
        }
    }

    struct Keyframe: Codable, Equatable, Sendable {
        /// Seconds from the start of the animation.
        var time: Double
        var value: Double
        /// The curve from the keyframe before to this one.
        var ease: Ease = .linear
    }

    /// Where a part shows.
    enum Clip: String, Codable, Sendable {
        /// Only above its own bottom edge, as if rising from behind a line.
        case aboveBaseline
    }

    struct Track: Codable, Equatable, Sendable {
        var part: PartID
        /// Hidden until then (nil: always drawn).
        var appears: Double?
        /// The point scaling and rotation turn round, in the part's box (0…1, origin top left).
        var anchor = CGPoint(x: 0.5, y: 0.5)
        var clip: Clip?
        /// Its outline is drawn (in the part's colour) as well as its fill.
        var stroked = false
        var keys: [Property: [Keyframe]] = [:]

        func value(_ property: Property, at t: Double) -> Double {
            guard let keys = keys[property], let first = keys.first else { return property.rest }
            guard t > first.time else { return first.value }
            for (before, after) in zip(keys, keys.dropFirst()) where t < after.time {
                guard t > before.time else { return before.value }
                let p = (t - before.time) / (after.time - before.time)
                return before.value + (after.value - before.value) * after.ease(p)
            }
            return keys.last!.value
        }

        /// A move of one property from `from` at `start` to `to` at `end`.
        mutating func move(_ property: Property, from: Double, to: Double, start: Double, end: Double, ease: Ease) {
            keys[property] = [Keyframe(time: start, value: from), Keyframe(time: end, value: to, ease: ease)]
        }

        var end: Double { keys.values.compactMap { $0.last?.time }.max() ?? appears ?? 0 }
    }

    struct Wipe: Codable, Equatable, Sendable {
        /// From 0 (nothing shows) to 1 (all of it), left to right.
        var progress: [Keyframe]
        /// The soft edge, as a part of the logo's width.
        var softness: Double

        func value(at t: Double) -> Double {
            Track(part: .init(index: -1), keys: [.opacity: progress]).value(.opacity, at: t)
        }
    }

    /// When the last move ends.
    var duration: Double {
        max(tracks.map(\.end).max() ?? 0, wipe?.progress.last?.time ?? 0)
    }
}

extension Easing {
    /// A CSS-style cubic Bézier from (0, 0) to (1, 1) with control points (x1, y1) and (x2, y2).
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        func curve(_ a: Double, _ b: Double, _ s: Double) -> Double {
            3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
        }
        // Find s where the curve's x is `x` (Newton, then halving if it strays).
        var s = x
        for _ in 0..<8 {
            let error = curve(x1, x2, s) - x
            let slope = 3 * x1 * (1 - s) * (1 - s) + 6 * (x2 - x1) * s * (1 - s) + 3 * (1 - x2) * s * s
            guard abs(error) > 1e-7 else { break }
            guard abs(slope) > 1e-6 else { break }
            s = min(max(s - error / slope, 0), 1)
        }
        var low = 0.0, high = 1.0
        while abs(curve(x1, x2, s) - x) > 1e-6, high - low > 1e-9 {
            if curve(x1, x2, s) < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return curve(y1, y2, s)
    }
}

extension LogoAnimation {
    /// Where an animation comes from: one of the styles, or a spec of its own.
    enum Source: Sendable {
        case template(Style)
        case custom(MotionSpec)
    }

    /// The styles drawn from a spec; the others keep their own drawing code.
    static let specStyles: Set<Style> = [.elegant, .rise, .wipe, .build, .pop, .cascade, .reveal]

    /// A classic style as a spec for this logo (nil for the procedural styles).
    func motionSpec(for chosen: Style) -> MotionSpec? {
        let style = chosen == .automatic ? suggestedStyle : chosen
        guard Self.specStyles.contains(style) else { return nil }
        let timing = timing(style)
        var tracks: [MotionSpec.Track] = []
        for (index, element) in elements.enumerated() {
            let (start, length) = timing[index]
            let end = start + length
            /// The moment a part of the move is done (`fraction` of its length).
            func at(_ fraction: Double) -> Double { start + length * fraction }
            var track = MotionSpec.Track(part: .init(index: index), appears: start)
            switch style {
            case .elegant:
                // Up a little, out of a soft focus, without any bounce.
                track.move(.translateY, from: size.height * 0.09, to: 0, start: start, end: end, ease: .outQuint)
                track.move(.scale, from: 1.03, to: 1, start: start, end: end, ease: .outQuint)
                track.move(.focus, from: 1, to: 0, start: start, end: at(1 / 1.15), ease: .outCubic)
                track.move(.opacity, from: 0, to: 1, start: start, end: at(1 / 1.6), ease: .outCubic)
            case .rise:
                if element.kind == .letter || element.kind == .accent {
                    // From behind the line the letter stands on.
                    track.clip = .aboveBaseline
                    track.move(.translateY, from: element.box.height * 1.05, to: 0, start: start, end: end, ease: .outQuint)
                    track.move(.opacity, from: 0, to: 1, start: start, end: at(0.25), ease: .linear)
                } else {
                    track.move(.scale, from: 0.86, to: 1, start: start, end: end, ease: .outExpo)
                    track.move(.focus, from: 1, to: 0, start: start, end: end, ease: .outQuint)
                    track.move(.opacity, from: 0, to: 1, start: start, end: at(1 / 1.8), ease: .outCubic)
                }
            case .wipe:
                // Behind the edge, a slight drift into place and out of focus.
                track.appears = nil
                track.move(.translateX, from: -size.width * 0.025, to: 0, start: start, end: end, ease: .outCubic)
                track.move(.focus, from: 0.6, to: 0, start: start, end: end, ease: .outCubic)
            case .build:
                if element.kind == .symbol || element.kind == .plate {
                    // The outline draws itself, then the shape fills in and the line fades.
                    track.stroked = true
                    track.move(.strokeTrim, from: 0, to: 1, start: start, end: at(0.7), ease: .inOutCubic)
                    track.move(.opacity, from: 0, to: 1, start: at(0.55), end: end, ease: .outCubic)
                    track.move(.strokeOpacity, from: 1, to: 0, start: at(0.55), end: end, ease: .outCubic)
                    track.move(.scale, from: 0.92, to: 1, start: start, end: at(0.8), ease: .outBack)
                } else {
                    // Letters roll up into place with a little overshoot, turning round their foot.
                    track.anchor = CGPoint(x: 0.5, y: 1)
                    track.move(.translateY, from: element.box.height * 0.7, to: 0, start: start, end: end, ease: .outBack)
                    track.move(.rotation, from: -0.18, to: 0, start: start, end: end, ease: .outBack)
                    track.move(.opacity, from: 0, to: 1, start: start, end: at(1 / 1.6), ease: .outCubic)
                }
            case .pop:
                track.move(.scale, from: 0, to: 1, start: start, end: end, ease: .spring)
                track.move(.rotation, from: 0.25, to: 0, start: start, end: end, ease: .outCubic)
                track.move(.opacity, from: 0, to: 1, start: start, end: at(1 / 2.5), ease: .outCubic)
            case .cascade:
                track.move(.translateX, from: size.width * 0.12, to: 0, start: start, end: end, ease: .outExpo)
                track.move(.stretch, from: 1.25, to: 1, start: start, end: end, ease: .outCubic)
                track.move(.opacity, from: 0, to: 1, start: start, end: at(0.5), ease: .outCubic)
            case .reveal:
                track.move(.translateY, from: element.box.height * 0.25, to: 0, start: start, end: end, ease: .outCubic)
                track.move(.scale, from: 0.94, to: 1, start: start, end: end, ease: .outCubic)
                track.move(.opacity, from: 0, to: 1, start: start, end: end, ease: .outCubic)
            default:
                break
            }
            tracks.append(track)
        }
        var spec = MotionSpec(tracks: tracks)
        if style == .wipe {
            spec.wipe = MotionSpec.Wipe(progress: [.init(time: 0, value: 0), .init(time: Self.wipeLength, value: 1, ease: .inOutCubic)],
                                        softness: 0.28)
        }
        return spec
    }

    /// Draws a spec at time `t` (seconds). `place` turns a box in the logo into the canvas.
    func draw(_ spec: MotionSpec, at t: Double, fit: Double, drawn: CGSize, canvas: CGSize, place: (CGRect) -> CGRect,
              point: (CGPoint) -> CGPoint, in context: CGContext) {
        let whole = place(CGRect(origin: .zero, size: size))
        if spec.wipe != nil { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        for track in spec.tracks {
            guard elements.indices.contains(track.part.index) else { continue }
            if let appears = track.appears, t <= appears { continue }
            let element = elements[track.part.index]
            let rect = place(element.box)
            func value(_ property: MotionSpec.Property) -> Double { track.value(property, at: t) }
            context.saveGState()
            if track.clip == .aboveBaseline {
                context.clip(to: CGRect(x: rect.minX - rect.width, y: rect.minY - 0.5, width: rect.width * 3, height: canvas.height))
            }
            let dx = value(.translateX), dy = value(.translateY)
            if dx != 0 || dy != 0 { context.translateBy(x: dx * fit, y: -dy * fit) }
            let stretch = value(.stretch), scale = value(.scale)
            let sx = value(.scaleX) * scale / stretch, sy = value(.scaleY) * scale * stretch
            let rotation = value(.rotation)
            if sx != 1 || sy != 1 || rotation != 0 {
                let anchor = CGPoint(x: rect.minX + track.anchor.x * rect.width, y: rect.minY + (1 - track.anchor.y) * rect.height)
                context.translateBy(x: anchor.x, y: anchor.y)
                if sx != 1 || sy != 1 { context.scaleBy(x: sx, y: sy) }
                if rotation != 0 { context.rotate(by: rotation) }
                context.translateBy(x: -anchor.x, y: -anchor.y)
            }
            if track.stroked {
                let strokeOpacity = value(.strokeOpacity), trim = value(.strokeTrim)
                if strokeOpacity > 0, trim > 0 {
                    context.saveGState()
                    context.setStrokeColor(element.colour)
                    context.setAlpha(strokeOpacity)
                    context.setLineWidth(max(1.5, min(drawn.width, drawn.height) * 0.012))
                    context.setLineJoin(.round)
                    context.setLineCap(.round)
                    for outline in element.outlines { strokePart(of: outline.map(point), fraction: trim, in: context) }
                    context.restoreGState()
                }
            }
            let opacity = value(.opacity)
            if opacity > 0 {
                drawSoft(element, in: rect, focus: value(.focus), alpha: opacity, scale: fit, context: context)
            }
            context.restoreGState()
        }
        if let wipe = spec.wipe {
            // The reveal: everything left of the soft edge shows.
            let w = wipe.value(at: t)
            let soft = whole.width * wipe.softness
            let edge = whole.minX - 2 + (whole.width + soft + 4) * w
            let colours = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours, locations: [0, 1]) {
                context.setBlendMode(.destinationIn)
                context.drawLinearGradient(gradient, start: CGPoint(x: edge - soft, y: 0), end: CGPoint(x: edge, y: 0),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.setBlendMode(.normal)
            }
            context.endTransparencyLayer()
        }
    }
}
