import AppKit
import SwiftUI
import QuartzCore

/// Decodes frames ahead of the playhead on several decoders at once, so playback shows each frame
/// when it's due instead of starting to decode it then.
///
/// Frames are counted in positions that keep rising as playback loops, so the frames after the
/// loop point decode before it's reached.
final class RawFramePipeline: @unchecked Sendable {
    private let decoders: [RawSource]
    private let condition = NSCondition()
    private var ready: [Int: CGImage] = [:]
    private var busy = Set<Int>()
    private var next: Int
    private var playhead: Int
    private var running = true
    /// How long decoding a frame takes on one decoder (seconds, averaged).
    private var decodeTime = 0.0
    let range: ClosedRange<Int>
    let scale: Int
    let settings: RawSettings
    let loops: Bool
    /// Frames decoded or decoding ahead of the playhead, at most.
    let ahead: Int

    init(decoders: [RawSource], start: Int, range: ClosedRange<Int>, scale: Int, settings: RawSettings, loops: Bool, frameBytes: Int) {
        // Very large frames: four decoders are plenty (and each holds a lot of memory).
        self.decoders = frameBytes > 20 << 20 ? Array(decoders.prefix(4)) : decoders
        self.range = range
        self.scale = scale
        self.settings = settings
        self.loops = loops
        next = start
        playhead = start
        // Enough to ride out a slow frame, in at most about 400 MB (a full-size 6K frame is 75 MB).
        ahead = max(3, min(max(self.decoders.count * 2, 6), (400 << 20) / max(frameBytes, 1)))
        for decoder in self.decoders {
            let thread = Thread { [weak self] in self?.work(decoder) }
            thread.qualityOfService = .userInteractive
            thread.start()
        }
    }

    /// The clip's frame at a position.
    func frame(at position: Int) -> Int {
        guard loops, position > range.upperBound else { return position }
        return range.lowerBound + (position - range.lowerBound) % range.count
    }

    private func work(_ decoder: RawSource) {
        while true {
            condition.lock()
            while running && (ready.count + busy.count >= ahead || (!loops && max(next, playhead) > range.upperBound)) {
                condition.wait()
            }
            guard running else { condition.unlock(); return }
            // What's already late isn't worth decoding.
            let position = max(next, playhead)
            next = position + 1
            busy.insert(position)
            condition.unlock()

            let began = Date.now
            let image = try? decoder.displayFrame(frame(at: position), scale: scale, settings: settings)
            let took = Date.now.timeIntervalSince(began)

            condition.lock()
            busy.remove(position)
            decodeTime = decodeTime == 0 ? took : decodeTime * 0.8 + took * 0.2
            if let image, position >= playhead { ready[position] = image }
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The frame for a position if it's decoded, moving the playhead there (frames before it are
    /// let go).
    func take(_ position: Int) -> CGImage? {
        condition.lock()
        defer { condition.unlock() }
        if position > playhead {
            playhead = position
            ready = ready.filter { $0.key >= position }
            condition.broadcast()
        }
        return ready[position]
    }

    /// Decoded frames waiting from a position on, in a row.
    func buffered(from position: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        var count = 0
        while ready[position + count] != nil { count += 1 }
        return count
    }

    /// Frames a second the decoders can make at this size.
    var capacity: Double {
        condition.lock()
        defer { condition.unlock() }
        return decodeTime > 0 ? Double(decoders.count) / decodeTime : 0
    }

    func stop() {
        condition.lock()
        running = false
        ready = [:]
        condition.broadcast()
        condition.unlock()
    }
}

/// Calls back on every refresh of the screen (on the main thread), while it runs.
@MainActor
final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private let tick: () -> Void

    init(_ tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
    }

    func start() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(fire))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire() { tick() }
}

/// The picture: frames go straight onto a layer, so a playing clip doesn't redraw the page.
struct RawFrameView: NSViewRepresentable {
    let player: RawPlayer

    /// Tells the player how many pixels wide the picture is on screen.
    final class PictureView: NSView {
        var resized: ((Double) -> Void)?
        override func layout() {
            super.layout()
            resized?(bounds.width * (window?.backingScaleFactor ?? 2))
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PictureView()
        view.resized = { [weak player] pixels in MainActor.assumeIsolated { player?.viewPixels = pixels } }
        view.wantsLayer = true
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        player.present = { [weak layer] image in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = image
            CATransaction.commit()
        }
        layer.contents = player.currentImage
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: ()) {}
}

extension RawPictures {
    /// A frame as 8-bit BGRA (in its own colour space), which the screen takes without converting
    /// it on every refresh. Made on the decoding thread.
    static func forDisplay(_ image: CGImage) -> CGImage {
        guard image.bitsPerComponent != 8 || image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue != CGBitmapInfo.byteOrder32Little.rawValue,
              let space = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }
}
