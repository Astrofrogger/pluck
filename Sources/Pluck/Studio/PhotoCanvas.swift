import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// The developed photo, drawn straight from the GPU: no copy into memory and back, and only the
/// part on screen is worked out (at 100% that's a small piece of a large photo). In extended
/// range, so what's brighter than white can show on an HDR screen.
struct PhotoCanvas: NSViewRepresentable {
    let image: CIImage?
    /// Where the whole photo goes, in points from the view's top left (it may reach past the view).
    let frame: CGRect
    /// Before and after: "before" is drawn with the same zoom and place as `image`, to the left of
    /// the line (`split`, a share of the photo that shows), or in the left half with `image` in the
    /// right half (then `frame` is the one in the right half).
    var before: CIImage?
    var mode: BeforeAfter = .off
    var split = 0.5

    func makeNSView(context: Context) -> PhotoCanvasView { PhotoCanvasView() }

    func updateNSView(_ view: PhotoCanvasView, context: Context) { view.show(image, in: frame, before: before, mode: mode, split: split) }
}

/// What the canvas draws, as a picture (also for the self-test).
enum PhotoComposite {
    /// The part of the photo that shows in the view, in points: where the split line can go.
    static func visible(frame: CGRect, view: CGSize) -> CGRect { frame.intersection(CGRect(origin: .zero, size: view)) }

    /// Where the split line stands, in points from the view's left.
    static func splitX(frame: CGRect, view: CGSize, split: Double) -> Double {
        let shown = visible(frame: frame, view: view)
        return shown.minX + min(max(split, 0), 1) * shown.width
    }

    /// The view (`view` points at `scale` pixels per point): the surround, then the photo or the two.
    /// With `.sideBySide` `frame` is the "after" in the right half and "before" gets the left half's.
    static func compose(after: CIImage?, before: CIImage?, frame: CGRect, mode: BeforeAfter, split: Double,
                        view: CGSize, scale: CGFloat) -> CIImage {
        let size = CGSize(width: view.width * scale, height: view.height * scale)
        let screen = CGRect(origin: .zero, size: size)
        let grey = Design.Photo.surroundWhite
        var picture = CIImage(color: CIColor(red: grey, green: grey, blue: grey, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? .black)
            .cropped(to: screen)
        /// `clip` is in pixels from the bottom left.
        func place(_ image: CIImage?, in target: CGRect, clip: CGRect) {
            guard let image, image.extent.width > 0, image.extent.height > 0, !image.extent.isInfinite, target.width > 0 else { return }
            let area = clip.intersection(screen)
            guard !area.isEmpty else { return }
            let e = image.extent
            // The frame in drawable pixels, from the bottom left.
            let sx = target.width * scale / e.width, sy = target.height * scale / e.height
            let x = target.minX * scale, y = size.height - target.maxY * scale
            let move = CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: x, y: y))
            // Photo pixels show as sharp squares when they're much bigger than the screen's.
            let placed = (sx > 2 ? image.samplingNearest() : image).transformed(by: move)
            picture = placed.cropped(to: area).composited(over: picture)
        }
        switch mode {
        case .off:
            place(after, in: frame, clip: screen)
        case .split:
            let line = splitX(frame: frame, view: view, split: split) * scale
            place(before ?? after, in: frame, clip: CGRect(x: 0, y: 0, width: line, height: size.height))
            place(after, in: frame, clip: CGRect(x: line, y: 0, width: size.width - line, height: size.height))
        case .sideBySide:
            let half = size.width / 2
            place(before, in: frame.offsetBy(dx: -view.width / 2, dy: 0), clip: CGRect(x: 0, y: 0, width: half, height: size.height))
            place(after, in: frame, clip: CGRect(x: half, y: 0, width: half, height: size.height))
        }
        return picture
    }
}

final class PhotoCanvasView: MTKView, MTKViewDelegate {
    private var image: CIImage?
    private var target: CGRect = .zero
    private var before: CIImage?
    private var mode: BeforeAfter = .off
    private var split = 0.5
    private let queue = PhotoEngine.device?.makeCommandQueue()
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    init() {
        super.init(frame: .zero, device: PhotoEngine.device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 0.022, green: 0.022, blue: 0.022, alpha: 1)
        if let layer = layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = space
            layer.isOpaque = true
        }
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The gestures are SwiftUI's, over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The screen's room above white changes with its brightness and with the screen: looked at
    /// every two seconds while shown (macOS doesn't say when), in quarter steps.
    private var headroomTimer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        headroomTimer?.invalidate()
        headroomTimer = nil
        guard window != nil else { return }
        let check = { [weak self] in
            MainActor.assumeIsolated {
                let room = (PhotoEditing.headroom(of: self?.window?.screen) * 4).rounded(.down) / 4
                if PhotoEditing.shared.headroom != room { PhotoEditing.shared.headroom = room }
            }
        }
        check()
        headroomTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in check() }
    }

    func show(_ image: CIImage?, in frame: CGRect, before: CIImage? = nil, mode: BeforeAfter = .off, split: Double = 0.5) {
        guard image !== self.image || frame != target || before !== self.before || mode != self.mode || split != self.split else { return }
        self.image = image
        target = frame
        self.before = before
        self.mode = mode
        self.split = split
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let buffer = queue?.makeCommandBuffer() else { return }
        let size = drawableSize
        let scale = size.width / max(bounds.width, 1)
        let picture = PhotoComposite.compose(after: image, before: before, frame: target, mode: mode, split: split,
                                             view: bounds.size, scale: scale)
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: colorPixelFormat,
                                              commandBuffer: buffer) { drawable.texture }
        destination.colorSpace = space
        _ = try? PhotoEngine.context.startTask(toRender: picture, to: destination)
        buffer.present(drawable)
        buffer.commit()
    }
}
