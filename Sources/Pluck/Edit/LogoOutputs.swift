import CoreGraphics
import Foundation

/// What the animation is for: a full reveal, an intro, a short sting, a seamless loop, or a still.
/// Each is the same concept made longer or shorter, not the same one sped up.
enum LogoOutput: String, CaseIterable, Identifiable, Sendable {
    case reveal, intro, sting, loop, still
    var id: String { rawValue }

    var label: String {
        switch self {
        case .reveal: String(localized: "Reveal")
        case .intro: String(localized: "Intro")
        case .sting: String(localized: "Sting")
        case .loop: String(localized: "Loop")
        case .still: String(localized: "Still")
        }
    }

    var help: String {
        switch self {
        case .reveal: String(localized: "The full reveal, unhurried (about 4 seconds)")
        case .intro: String(localized: "For the start of a video (about 3 seconds)")
        case .sting: String(localized: "A short signature for ads, reels and end cards (under 2 seconds)")
        case .loop: String(localized: "The finished logo moving gently, seamlessly, for a screen or a website")
        case .still: String(localized: "The finished logo as a picture (PNG) and a vector file (SVG)")
        }
    }

    /// The video's length (seconds).
    var length: Double {
        switch self {
        case .reveal: 4
        case .intro: 3
        case .sting: 1.6
        case .loop, .still: 0
        }
    }

    /// How much longer (more than 1) or shorter the concept's moves are.
    var pace: Double {
        switch self {
        case .reveal: 1.35
        case .sting: 0.62
        default: 1
        }
    }
}

/// The kind of file a video is written as.
enum LogoFile: String, CaseIterable, Identifiable, Sendable {
    case automatic, prores, h264, hevc, webm, gif, pngSequence
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .prores: String(localized: "ProRes 4444")
        case .h264: String(localized: "H.264")
        case .hevc: String(localized: "HEVC")
        case .webm: String(localized: "WebM")
        case .gif: String(localized: "GIF")
        case .pngSequence: String(localized: "PNG Sequence")
        }
    }

    var help: String {
        switch self {
        case .automatic: String(localized: "ProRes 4444 when transparent, otherwise H.264")
        case .prores: String(localized: "For editing: Final Cut Pro, DaVinci Resolve, Premiere. Keeps transparency.")
        case .h264: String(localized: "Plays everywhere. No transparency.")
        case .hevc: String(localized: "Small, with transparency on Apple devices and in Final Cut Pro")
        case .webm: String(localized: "For websites, with transparency")
        case .gif: String(localized: "For chats and email: small, up to 25 frames a second")
        case .pngSequence: String(localized: "A folder of numbered pictures, with transparency")
        }
    }

    /// The file this choice writes for a background (transparent or not).
    func resolved(transparent: Bool) -> LogoFile {
        self == .automatic ? (transparent ? .prores : .h264) : self
    }

    /// Whether it keeps transparency.
    var hasAlpha: Bool { [.prores, .hevc, .webm, .gif, .pngSequence].contains(self) }

    var fileExtension: String {
        switch self {
        case .automatic, .prores, .hevc: "mov"
        case .h264: "mp4"
        case .webm: "webm"
        case .gif: "gif"
        case .pngSequence: ""
        }
    }

    /// Sound goes in everything but pictures.
    var carriesSound: Bool { ![.gif, .pngSequence].contains(self) }

    func videoArguments(transparent: Bool, frameRate: Int, width: Int) -> [String] {
        // Converted with the BT.709 matrix and tagged so: untagged, Apple's apps guess another
        // matrix and every colour shifts.
        let tags = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        func convert(_ format: String) -> [String] { ["-vf", "scale=out_color_matrix=bt709:out_range=tv,format=\(format)"] }
        switch self {
        case .automatic, .prores:
            let format = transparent ? "yuva444p10le" : "yuv444p10le"
            return convert(format) + ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", format, "-vendor", "apl0"] + tags
        case .h264:
            return convert("yuv420p") + ["-c:v", "libx264", "-preset", "slow", "-crf", "14", "-pix_fmt", "yuv420p", "-movflags", "+faststart"] + tags
        case .hevc:
            // With transparency the encoder takes the picture as it is (and converts it itself).
            return (transparent ? ["-vf", "setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709"] : convert("yuv420p"))
                + ["-c:v", "hevc_videotoolbox", "-q:v", "85", "-tag:v", "hvc1"]
                + (transparent ? ["-alpha_quality", "0.9", "-pix_fmt", "bgra"] : ["-pix_fmt", "yuv420p"]) + tags
        case .webm:
            let format = transparent ? "yuva420p" : "yuv420p"
            return convert(format) + ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "28", "-row-mt", "1", "-pix_fmt", format] + tags
        case .gif:
            // One palette for the whole animation, a transparent colour kept for the background.
            let scale = width > 960 ? ",scale=960:-1:flags=lanczos" : ""
            return ["-vf", "fps=\(min(frameRate, 25))\(scale),split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128",
                    "-loop", "0"]
        case .pngSequence:
            return ["-c:v", "png"]
        }
    }

    var audioArguments: [String] {
        switch self {
        case .automatic, .prores, .hevc: ["-c:a", "pcm_s16le"]
        case .h264: ["-c:a", "aac", "-b:a", "192k"]
        case .webm: ["-c:a", "libopus", "-b:a", "128k"]
        case .gif, .pngSequence: []
        }
    }

    /// Where ffmpeg writes: the file, or the numbered pictures inside a folder.
    func target(_ output: URL) -> String {
        self == .pngSequence ? output.appendingPathComponent(output.lastPathComponent + " %05d.png").path : output.path
    }
}

extension LogoAnimation {
    // MARK: The resolve

    /// When the hero has landed (spec time): the moment a sound's hit goes on.
    func resolveTime(of spec: MotionSpec) -> Double {
        let hero = Set(profile.hero)
        let ends = spec.tracks.filter { hero.contains($0.part.index) }.map(\.end)
        return ends.max() ?? spec.duration
    }

    /// When the hero has landed in a video of this plan (video time).
    func resolveTime(of plan: Plan) -> Double {
        switch plan.source {
        case .custom(let spec): resolveTime(of: spec) / plan.speed
        case .template: plan.intro
        }
    }

    // MARK: The loop

    /// A seamless idle of the finished logo: the hero moves gently and comes back to exactly where
    /// it started, the rest stays still. A shape that looks the same turned turns one step, a
    /// round one orbits, a line has a trace run round it, anything else breathes. Never flashes.
    func loopSpec() -> MotionSpec {
        var tracks = elements.indices.map { MotionSpec.Track(part: .init(index: $0)) }
        let p = profile
        let hero = p.hero
        guard !hero.isEmpty else { return MotionSpec(tracks: tracks) }
        let box = union(hero)
        let centre = CGPoint(x: box.midX, y: box.midY)
        func anchor(_ i: Int) -> CGPoint {
            let b = elements[i].box
            return CGPoint(x: (centre.x - b.minX) / max(b.width, 1), y: (centre.y - b.minY) / max(b.height, 1))
        }
        /// Keys of a smooth wave through a period (straight lines between close samples).
        func wave(_ period: Double, _ value: (Double) -> Double) -> [MotionSpec.Keyframe] {
            (0...24).map { k in
                let t = period * Double(k) / 24
                return MotionSpec.Keyframe(time: t, value: value(Double(k) / 24), ease: .linear)
            }
        }
        if p.heroShape == .stroke {
            let period = 3.0
            for i in hero {
                tracks[i].stroked = true
                tracks[i].keys[.strokeTrim] = [.init(time: 0, value: 0), .init(time: period, value: 1, ease: .linear)]
                tracks[i].keys[.strokeOpacity] = [.init(time: 0, value: 0), .init(time: period * 0.15, value: 0.7, ease: .linear),
                                                  .init(time: period * 0.85, value: 0.7, ease: .linear), .init(time: period, value: 0, ease: .linear)]
            }
        } else if p.heroSymmetry.turns >= 3 {
            let period = 6.0, step = 2 * Double.pi / Double(p.heroSymmetry.turns)
            for i in hero {
                tracks[i].anchor = anchor(i)
                tracks[i].keys[.rotation] = [.init(time: 0, value: 0), .init(time: period, value: -step, ease: .linear)]
            }
        } else if hero.count == 1, p.shapes[hero[0]] == .circle {
            let period = 4.0, radius = box.width * 0.03
            tracks[hero[0]].keys[.translateX] = wave(period) { radius * sin(2 * .pi * $0) }
            tracks[hero[0]].keys[.translateY] = wave(period) { radius * (1 - cos(2 * .pi * $0)) }
        } else {
            let period = 4.0
            for i in hero {
                tracks[i].anchor = anchor(i)
                tracks[i].keys[.scale] = wave(period) { 1 + 0.025 * pow(sin(.pi * $0), 2) }
            }
        }
        return MotionSpec(tracks: tracks)
    }

    /// A plan for the loop: the whole video is one turn of it, no hold, nothing sped up.
    func loopPlan() -> Plan {
        let spec = loopSpec()
        let period = max(spec.duration, 1)
        return Plan(source: .custom(spec), outro: .none, total: period, speed: 1, intro: period, outroLength: 0)
    }
}

extension LogoAnimation {
    // MARK: Vertical

    /// For tall formats: the symbol centred above the name (a symbol beside a name would be small
    /// in a tall frame). Nil when the logo is already stacked or has no symbol beside a name.
    func stacked() -> LogoAnimation? {
        guard [.symbolLeft, .symbolRight].contains(profile.layout) else { return nil }
        let symbol = Set(elements.indices.filter { profile.roles[$0] == .symbol || profile.roles[$0] == .plate })
        let name = elements.indices.filter { !symbol.contains($0) }
        guard !symbol.isEmpty, !name.isEmpty else { return nil }
        let symbolBox = union(Array(symbol)), nameBox = union(name)
        let gap = nameBox.height * 0.4, pad = 8.0
        let width = max(symbolBox.width, nameBox.width) + pad * 2
        let height = symbolBox.height + gap + nameBox.height + pad * 2
        let size = CGSize(width: width.rounded(.up), height: height.rounded(.up))
        // Where each part moves (logo pixels, whole pixels so the parts stay sharp).
        let symbolShift = CGPoint(x: ((width - symbolBox.width) / 2 - symbolBox.minX).rounded(), y: (pad - symbolBox.minY).rounded())
        let nameShift = CGPoint(x: ((width - nameBox.width) / 2 - nameBox.minX).rounded(), y: (pad + symbolBox.height + gap - nameBox.minY).rounded())
        var moved = elements
        for i in moved.indices {
            let shift = symbol.contains(i) ? symbolShift : nameShift
            moved[i].box = moved[i].box.offsetBy(dx: shift.x, dy: shift.y)
            moved[i].outlines = moved[i].outlines.map { $0.map { CGPoint(x: $0.x + shift.x, y: $0.y + shift.y) } }
            var move = CGAffineTransform(translationX: shift.x, y: shift.y)
            moved[i].vector = moved[i].vector?.compactMap { shape in
                shape.path.copy(using: &move).map { VectorArt.Shape(path: $0, colour: shape.colour, evenOdd: shape.evenOdd, stroke: shape.stroke) }
            }
        }
        // The finished logo in its new layout, from its parts.
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for element in moved {
            element.draw(in: CGRect(x: element.box.minX, y: size.height - element.box.maxY, width: element.box.width, height: element.box.height), context)
        }
        guard let logo = context.makeImage() else { return nil }
        let vectors = moved.allSatisfy({ $0.vector != nil }) ? moved.flatMap { $0.vector ?? [] } : nil
        return LogoAnimation(logo: logo, size: size, elements: moved, vectorLogo: vectors, artDifference: artDifference, directed: directed)
    }

    /// Whether the logo sits inside a tall frame's safe zone (the middle 900×1400 of 1080×1920).
    static func insideSafeZone(_ rect: CGRect, canvas: CGSize) -> Bool {
        let zone = CGRect(x: canvas.width * (90 / 1080), y: canvas.height * (260 / 1920), width: canvas.width * (900 / 1080), height: canvas.height * (1400 / 1920))
        return zone.contains(rect)
    }
}

extension LogoAnimation {
    // MARK: Brand Pack

    /// The motion other tools (Brand Pack's end card) give this logo: the design saved for it in
    /// the Logo Animator, as a Sting, if there is one; otherwise the style Automatic suggests.
    func suggestedMotion(savedFor file: URL?) -> (plan: Plan, feel: LogoProfile.Personality) {
        if let file, let edits = LogoDesignStore.load(for: file),
           let design = design(edits: edits, pace: LogoOutput.sting.pace), design.valid {
            return (plan(.custom(design.spec), outro: .none, length: LogoOutput.sting.length), edits.feel ?? profile.personality())
        }
        return (plan(suggestedStyle, outro: .none), profile.personality())
    }
}
