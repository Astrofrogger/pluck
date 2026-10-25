import AVFoundation
import CoreImage
import ImageIO

/// What's on screen at each moment of a project: the main line's clip (two during a dissolve),
/// then the pictures laid over it, each placed as its look says. Read by the compositor while
/// the edit plays, so a look changed while dragging shows at once.
final class ProjectLayers: @unchecked Sendable {
    struct Span {
        var clip: UUID
        var trackID: CMPersistentTrackID
        /// The file (for its camera's log).
        var path = ""
        /// Where it's on screen (with a dissolve's extra frames), and the clip itself (its look's
        /// progress runs over that).
        var start: Double
        var end: Double
        var clipStart: Double
        var clipEnd: Double
        var look: ClipLook?
        var orientation: CGImagePropertyOrientation
        /// On the main line (drawn on black), or laid over it.
        var main: Bool
        /// Fades in over its first seconds, out over its last (a dissolve's two halves).
        var fadeIn = 0.0
        var fadeOut = 0.0
    }

    private var spans: [Span] = []
    private var mainEntries: [(start: Double, end: Double)] = []
    private var dips: [(in: ProjectDip?, out: ProjectDip?)] = []
    private var adjustments: [ProjectAdjustment] = []
    private let lock = NSLock()

    func replace(_ new: [Span], main: [(start: Double, end: Double)], dips: [(in: ProjectDip?, out: ProjectDip?)]) {
        lock.withLock { spans = new; mainEntries = main; self.dips = dips }
    }

    func setAdjustments(_ new: [ProjectAdjustment]) {
        lock.withLock { adjustments = new.filter(\.isVisible) }
    }

    /// The looks over the timeline at a time, in order.
    func adjustments(at seconds: Double) -> [ProjectAdjustment] {
        lock.withLock { adjustments.filter { $0.contains(seconds) } }
    }

    func setLook(_ clip: UUID, _ look: ClipLook?) {
        lock.withLock { for index in spans.indices where spans[index].clip == clip { spans[index].look = look } }
    }

    /// Bottom to top, with how opaque each is now.
    func layers(at seconds: Double) -> [(span: Span, alpha: Double)] {
        lock.withLock {
            spans.compactMap { span in
                guard seconds >= span.start - 0.0005, seconds < span.end + 0.0005 else { return nil }
                var alpha = 1.0
                if span.fadeIn > 0 { alpha = min(alpha, max((seconds - span.start) / span.fadeIn, 0)) }
                if span.fadeOut > 0 { alpha = min(alpha, max((span.end - seconds) / span.fadeOut, 0)) }
                return (span, alpha)
            }
        }
    }

    /// How far into a dip's colour the picture is at a time, if it's in one.
    func dip(_ seconds: Double) -> (amount: Double, white: Bool)? {
        lock.withLock {
            guard let index = mainEntries.lastIndex(where: { $0.start <= seconds + 0.0005 }), dips.indices.contains(index) else { return nil }
            let entry = mainEntries[index]
            return ProjectDip.amount(at: seconds - entry.start, length: entry.end - entry.start, dipIn: dips[index].in, dipOut: dips[index].out)
                .map { ($0.0, $0.1) }
        }
    }

    /// The look at a time on the main line (for the viewer's handles).
    func mainLook(at seconds: Double) -> (look: ClipLook?, progress: Double) {
        lock.withLock {
            guard let span = spans.last(where: { $0.main && $0.clipStart <= seconds + 0.0005 && seconds < $0.clipEnd + 0.0005 }) else { return (nil, 0) }
            return (span.look, (seconds - span.clipStart) / max(span.clipEnd - span.clipStart, 0.001))
        }
    }
}

/// One instruction for the whole edit: every track's frame, and the layers that say what to do.
final class ProjectInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let layers: ProjectLayers
    let size: CGSize

    init(timeRange: CMTimeRange, tracks: [CMPersistentTrackID], layers: ProjectLayers, size: CGSize) {
        self.timeRange = timeRange
        requiredSourceTrackIDs = tracks.map { NSNumber(value: $0) }
        self.layers = layers
        self.size = size
    }
}

/// Draws a project's frame: each layer's picture placed by its look and laid over the one below,
/// a dissolve blending two, a dip fading to a colour.
final class ProjectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Video's 709 as Core Media reads it (by name: the constant is macOS 15's).
    static let video = CGColorSpace(name: "kCGColorSpaceCoreMedia709" as CFString) ?? CGColorSpace(name: CGColorSpace.itur_709)!
    private let queue = DispatchQueue(label: "be.wideopen.pluck.compositor")

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async {
            guard let instruction = request.videoCompositionInstruction as? ProjectInstruction,
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Pluck", code: 1))
                return
            }
            let seconds = request.compositionTime.seconds
            let size = instruction.size
            let frame = CGRect(origin: .zero, size: size)
            var picture = CIImage(color: .black).cropped(to: frame)
            for (span, alpha) in instruction.layers.layers(at: seconds) where alpha > 0.001 {
                guard let buffer = request.sourceFrame(byTrackID: span.trackID) else { continue }
                // A camera's log made normal, from the file's own numbers.
                let source: CIImage
                if let camera = CameraLog.resolve(span.look?.color.camera, path: span.path) {
                    source = camera.apply(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])).oriented(span.orientation)
                } else {
                    source = CIImage(cvPixelBuffer: buffer).oriented(span.orientation)
                }
                let progress = (seconds - span.clipStart) / max(span.clipEnd - span.clipStart, 0.001)
                var placed = ClipLook.place(source, look: span.look, progress: min(max(progress, 0), 1), in: size, onBlack: span.main)
                if alpha < 0.999 {
                    let a = CGFloat(alpha)
                    placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
                                                                                 "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
                                                                                 "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                                                                                 "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0)])
                }
                picture = placed.composited(over: picture)
            }
            // Looks over this part of the timeline, on everything under them.
            for look in instruction.layers.adjustments(at: seconds) { picture = look.apply(picture).cropped(to: frame) }
            if let dip = instruction.layers.dip(seconds) {
                let colour = CIImage(color: dip.white ? .white : .black).cropped(to: frame)
                picture = picture.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: colour, kCIInputTimeKey: dip.amount])
            }
            // Video's own 709 (as the player reads the frame): Core Graphics' "ITU-R 709" has another
            // curve, which made the viewer's midtones lighter than the file and the export.
            Self.context.render(picture.cropped(to: frame), to: output, bounds: frame, colorSpace: Self.video)
            request.finish(withComposedVideoFrame: output)
        }
    }
}

extension CGImagePropertyOrientation {
    /// How a video track's preferred transform turns its picture (phones filmed upright).
    init(_ transform: CGAffineTransform) {
        let angle = atan2(transform.b, transform.a) * 180 / .pi
        switch angle.rounded() {
        case 90: self = .right
        case -90: self = .left
        case 180, -180: self = .down
        default: self = .up
        }
    }
}
