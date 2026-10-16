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

    func makeNSView(context: Context) -> PhotoCanvasView { PhotoCanvasView() }

    func updateNSView(_ view: PhotoCanvasView, context: Context) { view.show(image, in: frame) }
}

final class PhotoCanvasView: MTKView, MTKViewDelegate {
    private var image: CIImage?
    private var target: CGRect = .zero
    private let queue = PhotoEngine.device?.makeCommandQueue()
    private let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    init() {
        super.init(frame: .zero, device: PhotoEngine.device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
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

    func show(_ image: CIImage?, in frame: CGRect) {
        guard image !== self.image || frame != target else { return }
        self.image = image
        target = frame
        needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let buffer = queue?.makeCommandBuffer() else { return }
        let size = drawableSize
        let scale = size.width / max(bounds.width, 1)
        let screen = CGRect(origin: .zero, size: size)
        var picture = CIImage(color: .black).cropped(to: screen)
        if let image, image.extent.width > 0, image.extent.height > 0, !image.extent.isInfinite, target.width > 0 {
            let e = image.extent
            // The frame in drawable pixels, from the bottom left.
            let sx = target.width * scale / e.width, sy = target.height * scale / e.height
            let x = target.minX * scale, y = size.height - target.maxY * scale
            let place = CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: x, y: y))
            // Photo pixels show as sharp squares when they're much bigger than the screen's.
            let placed = (sx > 2 ? image.samplingNearest() : image).transformed(by: place)
            picture = placed.cropped(to: screen).composited(over: picture)
        }
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: colorPixelFormat,
                                              commandBuffer: buffer) { drawable.texture }
        destination.colorSpace = space
        _ = try? PhotoEngine.context.startTask(toRender: picture, to: destination)
        buffer.present(drawable)
        buffer.commit()
    }
}
