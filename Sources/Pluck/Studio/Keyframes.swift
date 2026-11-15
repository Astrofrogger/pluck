import Foundation
import SwiftUI

/// How a keyframe's value goes to the next one's: straight, held, eased, or along a cubic-Bézier
/// curve (time across, value up, as CSS's cubic-bezier and After Effects' speed graph).
struct KeyEase: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case linear, hold, easeIn, easeOut, easeInOut, custom
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .linear: "Linear"
            case .hold: "Hold"
            case .easeIn: "Ease In"
            case .easeOut: "Ease Out"
            case .easeInOut: "Ease In and Out"
            case .custom: "Curve"
            }
        }
    }

    var kind = Kind.linear
    /// The two handles of a custom curve (x across 0…1; y may go past 0…1 to overshoot).
    var x1 = 0.33, y1 = 0.0, x2 = 0.67, y2 = 1.0

    static let linear = KeyEase()

    init(_ kind: Kind = .linear) {
        self.kind = kind
        if let h = Self.handles(kind) { (x1, y1, x2, y2) = h }
    }

    /// A custom curve with these handles.
    init(x1: Double, y1: Double, x2: Double, y2: Double) {
        kind = .custom
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// Each preset as a curve (hold has none).
    static func handles(_ kind: Kind) -> (Double, Double, Double, Double)? {
        switch kind {
        case .linear: (0.33, 0.33, 0.67, 0.67)
        case .hold: nil
        case .easeIn: (0.42, 0, 1, 1)
        case .easeOut: (0, 0, 0.58, 1)
        case .easeInOut: (0.42, 0, 0.58, 1)
        case .custom: nil
        }
    }

    /// The handles drawn in the curve editor (a preset's own, else the custom ones).
    var curve: (x1: Double, y1: Double, x2: Double, y2: Double) {
        if kind != .custom, let h = Self.handles(kind) { return h }
        return (x1, y1, x2, y2)
    }

    /// How far (0…1, or past it for an overshooting curve) the value is this far (0…1) through the segment.
    func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch kind {
        case .linear: return t
        case .hold: return t >= 1 ? 1 : 0
        default:
            let c = curve
            return Self.bezier(t, x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y2)
        }
    }

    /// A cubic Bézier from (0,0) to (1,1): its y where its x is `x` (x always rises: handles' x kept in 0…1).
    static func bezier(_ x: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        let ax = min(max(x1, 0), 1), bx = min(max(x2, 0), 1)
        func part(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
        }
        // x(s) rises with s: halve the gap (Newton can wander where the curve is flat).
        var low = 0.0, high = 1.0, s = x
        for _ in 0..<40 {
            let value = part(s, ax, bx)
            if abs(value - x) < 1e-7 { break }
            if value < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return part(s, y1, y2)
    }
}

/// A property's value at a moment of a clip (seconds from the clip's start on the timeline), and
/// how it goes on to the next one.
struct Keyframe: Codable, Hashable, Identifiable {
    var id = UUID()
    var time: Double
    var value: Double
    var ease = KeyEase.linear

    init(time: Double, value: Double, ease: KeyEase = .linear) {
        self.time = time; self.value = value; self.ease = ease
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        time = (try? c.decodeIfPresent(Double.self, forKey: .time)) ?? 0
        value = (try? c.decodeIfPresent(Double.self, forKey: .value)) ?? 0
        ease = (try? c.decodeIfPresent(KeyEase.self, forKey: .ease)) ?? .linear
    }
}

/// What can be keyframed on a clip.
enum KeyProperty: String, CaseIterable, Identifiable {
    case zoom, x, y, rotation, cropLeft, cropRight, cropTop, cropBottom, opacity
    case exposure, contrast, saturation, temperature, tint, lutAmount
    case volume
    var id: String { rawValue }

    var label: String {
        switch self {
        case .zoom: String(localized: "Zoom")
        case .x: String(localized: "Position X")
        case .y: String(localized: "Position Y")
        case .rotation: String(localized: "Rotation")
        case .cropLeft: String(localized: "Crop Left")
        case .cropRight: String(localized: "Crop Right")
        case .cropTop: String(localized: "Crop Top")
        case .cropBottom: String(localized: "Crop Bottom")
        case .opacity: String(localized: "Opacity")
        case .exposure: String(localized: "Exposure")
        case .contrast: String(localized: "Contrast")
        case .saturation: String(localized: "Saturation")
        case .temperature: String(localized: "Temperature")
        case .tint: String(localized: "Tint")
        case .lutAmount: String(localized: "LUT Amount")
        case .volume: String(localized: "Volume")
        }
    }

    /// Where it is in a look (volume, in dB, is the clip's own).
    var path: WritableKeyPath<ClipLook, Double>? {
        switch self {
        case .zoom: \.zoom
        case .x: \.x
        case .y: \.y
        case .rotation: \.rotation
        case .cropLeft: \.cropLeft
        case .cropRight: \.cropRight
        case .cropTop: \.cropTop
        case .cropBottom: \.cropBottom
        case .opacity: \.opacity
        case .exposure: \.color.exposure
        case .contrast: \.color.contrast
        case .saturation: \.color.saturation
        case .temperature: \.color.temperature
        case .tint: \.color.tint
        case .lutAmount: \.color.lutAmount
        case .volume: nil
        }
    }

    static var picture: [KeyProperty] { allCases.filter { $0.path != nil } }

    /// Resolve's Inspector name for it (nil: Resolve's scripting has no such setting).
    var resolveName: String? {
        switch self {
        case .zoom: "ZoomX"
        case .x: "Pan"
        case .y: "Tilt"
        case .rotation: "RotationAngle"
        case .cropLeft: "CropLeft"
        case .cropRight: "CropRight"
        case .cropTop: "CropTop"
        case .cropBottom: "CropBottom"
        case .opacity: "Opacity"
        default: nil
        }
    }
}

extension Array where Element == Keyframe {
    /// The value at a time: held before the first and after the last, else eased between the two around it.
    func value(at time: Double) -> Double? {
        guard let first = first else { return nil }
        if time <= first.time { return first.value }
        guard let last = last, time < last.time else { return last?.value }
        // Sorted by time (kept so by every change).
        var low = 0, high = count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if self[mid].time <= time { low = mid } else { high = mid }
        }
        let a = self[low], b = self[high]
        let span = b.time - a.time
        guard span > 1e-9 else { return b.value }
        return a.value + (b.value - a.value) * a.ease.apply((time - a.time) / span)
    }
}

extension ClipLook {
    var hasKeys: Bool { !(keys ?? [:]).isEmpty }

    func keyframes(_ property: KeyProperty) -> [Keyframe] { keys?[property.rawValue] ?? [] }

    func isKeyed(_ property: KeyProperty) -> Bool { !keyframes(property).isEmpty }

    var keyedProperties: [KeyProperty] { KeyProperty.allCases.filter(isKeyed) }

    mutating func setKeyframes(_ property: KeyProperty, _ frames: [Keyframe]) {
        var all = keys ?? [:]
        all[property.rawValue] = frames.isEmpty ? nil : frames.sorted { $0.time < $1.time }
        keys = all.isEmpty ? nil : all
    }

    /// The look this far (seconds) into its clip: every keyframed setting at its value there.
    func resolved(at time: Double) -> ClipLook {
        guard let keys, !keys.isEmpty else { return self }
        var look = self
        for property in KeyProperty.picture {
            if let path = property.path, let value = keys[property.rawValue]?.value(at: time) { look[keyPath: path] = value }
        }
        return look
    }

    /// The keyframe on this time (within half a frame), if there is one.
    func keyframe(_ property: KeyProperty, at time: Double, tolerance: Double = 0.02) -> Keyframe? {
        keyframes(property).first { abs($0.time - time) <= tolerance }
    }

    /// Sets a keyframe there (or changes the one there).
    mutating func setKey(_ property: KeyProperty, _ value: Double, at time: Double, tolerance: Double = 0.02) {
        var frames = keyframes(property)
        if let i = frames.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            frames[i].value = value
        } else {
            // A new one eases as the one before it does.
            let ease = frames.last(where: { $0.time < time })?.ease ?? .linear
            frames.append(Keyframe(time: max(time, 0), value: value, ease: ease))
        }
        setKeyframes(property, frames)
    }

    /// The diamond: a keyframe added there with the value shown, or the one there taken away.
    /// The last one taken away leaves the setting at its value then.
    mutating func toggleKey(_ property: KeyProperty, at time: Double, value: Double, tolerance: Double = 0.02) {
        var frames = keyframes(property)
        if let i = frames.firstIndex(where: { abs($0.time - time) <= tolerance }) {
            frames.remove(at: i)
            if frames.isEmpty, let path = property.path { self[keyPath: path] = value }
            setKeyframes(property, frames)
        } else {
            setKey(property, value, at: time, tolerance: tolerance)
        }
    }

    /// A change made to the look as shown at `time` (a slider, a handle on the viewer): a setting
    /// that's keyframed gets a keyframe there; the rest change as before.
    mutating func edit(at time: Double?, _ body: (inout ClipLook) -> Void) {
        guard let time, hasKeys else { body(&self); return }
        let shown = resolved(at: time)
        var edited = shown
        body(&edited)
        var result = edited
        // Keys changed by the edit itself (a diamond, Reset) win.
        if edited.keys == shown.keys {
            for property in KeyProperty.picture where isKeyed(property) {
                guard let path = property.path else { continue }
                result[keyPath: path] = self[keyPath: path]
                if abs(edited[keyPath: path] - shown[keyPath: path]) > 1e-9 { result.setKey(property, edited[keyPath: path], at: time) }
            }
        }
        self = result
    }

    /// Every keyframe moved in time by the same share (pasted onto a clip of another length).
    func stretchedKeys(by factor: Double) -> [String: [Keyframe]]? {
        keys?.mapValues { $0.map { var k = $0; k.time *= factor; k.id = UUID(); return k } }
    }
}

extension ProjectClip {
    /// Its volume (gain) this far into it: keyframed in dB, else its own.
    func gain(at time: Double) -> Double {
        guard let db = look?.keyframes(.volume).value(at: time) else { return volume }
        return pow(10, db / 20)
    }

    /// The volume keyframes as (time, gain) points close enough for straight pieces between
    /// them, `offset` seconds later (the clip's place in the stream or on the timeline), over `length`.
    func gainPoints(offset: Double, length: Double, step: Double = 0.05) -> [(time: Double, gain: Double)] {
        let frames = look?.keyframes(.volume) ?? []
        guard !frames.isEmpty else { return [] }
        var times: [Double] = [0, length]
        for (a, b) in zip(frames, frames.dropFirst()) {
            times.append(a.time)
            if a.ease.kind == .hold {
                times.append(max(b.time - 0.0005, a.time))
            } else {
                // (dB to gain isn't straight, even between two linear keyframes.)
                var t = a.time + step
                while t < b.time { times.append(t); t += step }
            }
        }
        if let last = frames.last { times.append(last.time) }
        let sorted = Array(Set(times.filter { $0 >= 0 && $0 <= length })).sorted()
        return sorted.map { (offset + $0, gain(at: $0)) }
    }

    /// Its keyframes pasted from another clip: at their own times, or stretched from that clip's length to this one's.
    mutating func pasteKeys(_ keys: [String: [Keyframe]], from length: Double, stretch: Bool) {
        var look = self.look ?? ClipLook()
        var source = ClipLook()
        source.keys = keys
        let pasted = stretch && length > 0 ? source.stretchedKeys(by: self.length / length) : source.stretchedKeys(by: 1)
        for (name, frames) in pasted ?? [:] {
            guard let property = KeyProperty(rawValue: name) else { continue }
            look.setKeyframes(property, frames.filter { $0.time <= self.length + 0.001 })
        }
        self.look = look.isDefault ? nil : look
    }
}

/// Keyframes copied from a clip (shared by every project open), with that clip's length for
/// "Paste and Stretch to Fit"; and a curve copied, to paste on others.
@MainActor
enum KeyClipboard {
    static var keys: (frames: [String: [Keyframe]], length: Double)?
    static var curve: KeyEase?
}

extension ClipLook {
    /// The clip now starts `delta` seconds (timeline) later in its footage (cut in two, trimmed):
    /// its keyframes move with the footage; those now before its start leave their value there.
    mutating func shiftKeys(by delta: Double) {
        guard let keys, abs(delta) > 1e-9 else { return }
        var moved: [String: [Keyframe]] = [:]
        for (name, frames) in keys {
            var kept = frames.filter { $0.time >= delta - 1e-9 }.map { var k = $0; k.time -= delta; return k }
            if frames.contains(where: { $0.time < delta - 1e-9 }), kept.first.map({ $0.time > 1e-9 }) ?? true, let value = frames.value(at: delta) {
                let ease = frames.last(where: { $0.time < delta })?.ease ?? .linear
                kept.insert(Keyframe(time: 0, value: value, ease: ease), at: 0)
            }
            moved[name] = kept
        }
        self.keys = moved
    }
}
