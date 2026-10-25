import AppKit
import QuartzCore
import SwiftUI

/// How the player's picture (A) is compared with a held still (B).
enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case off, split, sideBySide

    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .split: String(localized: "Split View")
        case .sideBySide: String(localized: "Side by Side")
        }
    }
    var next: CompareMode {
        switch self {
        case .off: .split
        case .split: .sideBySide
        case .sideBySide: .off
        }
    }
}

/// Where each picture goes, in a view of this size. B is on the left (left of the line, or the
/// left half); A is on the right.
enum CompareLayout {
    /// The rect a picture of this size takes when fitted into a frame (centred, not stretched).
    static func fit(_ picture: CGSize, in frame: CGRect) -> CGRect {
        guard picture.width > 0, picture.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let scale = min(frame.width / picture.width, frame.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `a` and `b` are the frames the pictures are fitted into; `bVisible` is the part of B that
    /// shows (all of B's frame when side by side, the part left of the line when split). With A's
    /// size known, `b` is the rect A's picture fills, so B (of another shape or not) lines up with it
    /// (split) or has the size of A's picture (side by side).
    static func rects(mode: CompareMode, splitAt: Double, size: CGSize, aPicture: CGSize? = nil) -> (a: CGRect, b: CGRect, bVisible: CGRect) {
        let full = CGRect(origin: .zero, size: size)
        switch mode {
        case .off:
            return (full, full, .zero)
        case .split:
            let x = (size.width * min(max(splitAt, 0), 1)).rounded()
            let picture = aPicture.map { fit($0, in: full) } ?? full
            return (full, picture, CGRect(x: 0, y: 0, width: x, height: size.height))
        case .sideBySide:
            let half = (size.width / 2).rounded(.down)
            let left = CGRect(x: 0, y: 0, width: half, height: size.height)
            let right = CGRect(x: half, y: 0, width: size.width - half, height: size.height)
            // A's picture in its half; B's frame the same size, in the same place in the left half.
            let picture = aPicture.map { fit($0, in: right) } ?? right
            let b = aPicture == nil ? left : picture.offsetBy(dx: -half, dy: 0)
            return (right, b, left)
        }
    }
}

/// The layer the Raw Player draws on: picture A, and over it (or beside it) the held still B.
/// Frames go straight onto it, so a playing clip doesn't redraw the page.
final class ComparePictureLayer: CALayer {
    private let aLayer = CALayer()
    private let bClip = CALayer()
    private let bLayer = CALayer()
    private let line = CALayer()
    private let handle = CAShapeLayer()
    private let labelA = CATextLayer()
    private let labelB = CATextLayer()

    private(set) var mode = CompareMode.off
    private(set) var splitAt = 0.5
    /// The size of picture A, to fit B to it.
    private var aPicture: CGSize?

    override init() {
        super.init()
        backgroundColor = NSColor.black.cgColor
        for picture in [aLayer, bLayer] {
            picture.contentsGravity = .resizeAspect
            picture.magnificationFilter = .linear
            picture.minificationFilter = .trilinear
        }
        bClip.masksToBounds = true
        bClip.isHidden = true
        bClip.addSublayer(bLayer)
        line.backgroundColor = NSColor.white.cgColor
        line.shadowOpacity = 0.5
        line.shadowRadius = 1.5
        line.shadowOffset = .zero
        line.isHidden = true
        handle.fillColor = NSColor.white.cgColor
        handle.shadowOpacity = 0.4
        handle.shadowRadius = 2
        handle.shadowOffset = .zero
        handle.isHidden = true
        // Two small arrows on the handle.
        let arrows = CAShapeLayer()
        let arrowPath = CGMutablePath()
        arrowPath.move(to: CGPoint(x: 7, y: 14)); arrowPath.addLine(to: CGPoint(x: 3, y: 18)); arrowPath.addLine(to: CGPoint(x: 7, y: 22))
        arrowPath.move(to: CGPoint(x: 9, y: 14)); arrowPath.addLine(to: CGPoint(x: 13, y: 18)); arrowPath.addLine(to: CGPoint(x: 9, y: 22))
        arrows.path = arrowPath
        arrows.fillColor = nil
        arrows.strokeColor = NSColor.black.withAlphaComponent(0.7).cgColor
        arrows.lineWidth = 1.5
        arrows.lineCap = .round
        arrows.lineJoin = .round
        handle.addSublayer(arrows)
        for (label, text) in [(labelA, "A"), (labelB, "B")] {
            label.string = text
            label.fontSize = 11
            label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            label.alignmentMode = .center
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            label.cornerRadius = 4
            label.contentsScale = 2
            label.isHidden = true
        }
        for sub in [aLayer, bClip, line, handle, labelA, labelB] { addSublayer(sub) }
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    /// Picture A (what's playing).
    func setA(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aLayer.contents = image
        let size = image.map { CGSize(width: $0.width, height: $0.height) }
        if size != aPicture {
            aPicture = size
            if mode != .off { layoutSublayers() }
        }
        CATransaction.commit()
    }

    /// The held still, and how it's shown. Does nothing to A.
    func setCompare(mode: CompareMode, b: CGImage?, splitAt: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.mode = b == nil ? .off : mode
        self.splitAt = splitAt
        bLayer.contents = b
        layoutSublayers()
        CATransaction.commit()
    }

    /// The x of the line, in this layer's points (nil unless split).
    var lineX: CGFloat? {
        guard mode == .split else { return nil }
        return CompareLayout.rects(mode: mode, splitAt: splitAt, size: bounds.size, aPicture: aPicture).bVisible.maxX
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let size = bounds.size
        let r = CompareLayout.rects(mode: mode, splitAt: splitAt, size: size, aPicture: aPicture)
        aLayer.frame = r.a
        let on = mode != .off
        bClip.isHidden = !on
        bClip.frame = r.bVisible
        bLayer.frame = CGRect(x: r.b.minX - r.bVisible.minX, y: r.b.minY - r.bVisible.minY, width: r.b.width, height: r.b.height)
        let split = mode == .split
        line.isHidden = !split
        handle.isHidden = !split
        if split {
            let x = r.bVisible.maxX
            line.frame = CGRect(x: x - 1, y: 0, width: 2, height: size.height)
            let pill = CGRect(x: x - 8, y: size.height / 2 - 18, width: 16, height: 36)
            handle.frame = pill
            if handle.path == nil {
                let path = CGMutablePath()
                path.addRoundedRect(in: CGRect(origin: .zero, size: pill.size), cornerWidth: 8, cornerHeight: 8)
                handle.path = path
            }
        }
        // "A" and "B" in the corners of their sides, unless the line is right on top of them.
        let w: CGFloat = 20, h: CGFloat = 16, top = size.height - h - 8
        labelB.isHidden = !on || (split && r.bVisible.maxX < w + 24)
        labelA.isHidden = !on || (split && size.width - r.bVisible.maxX < w + 24)
        labelB.frame = CGRect(x: 8, y: top, width: w, height: h)
        labelA.frame = CGRect(x: (split ? size.width : r.a.maxX) - w - 8, y: top, width: w, height: h)
    }
}

/// A thin strip over the line that drags it (the picture below it keeps its own gestures).
struct CompareSplitStrip: View {
    let player: RawPlayer

    var body: some View {
        GeometryReader { geometry in
            if player.compare == .split, player.stillB != nil {
                CompareDragView(player: player, width: geometry.size.width)
                    .frame(width: 28, height: geometry.size.height)
                    .position(x: geometry.size.width * min(max(player.splitAt, 0), 1), y: geometry.size.height / 2)
            }
        }
    }
}

private struct CompareDragView: NSViewRepresentable {
    let player: RawPlayer
    let width: Double

    final class Strip: NSView {
        var moved: ((Double) -> Void)?
        var start: (x: CGFloat, at: Double)?
        var width = 1.0
        var current: (() -> Double)?
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { start = (event.locationInWindow.x, current?() ?? 0.5) }
        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            moved?(start.at + Double(event.locationInWindow.x - start.x) / max(width, 1))
        }
        override func mouseUp(with event: NSEvent) { start = nil }
    }

    func makeNSView(context: Context) -> Strip {
        let view = Strip()
        view.moved = { [weak player] at in MainActor.assumeIsolated { player?.splitAt = min(max(at, 0.02), 0.98) } }
        view.current = { [weak player] in MainActor.assumeIsolated { player?.splitAt ?? 0.5 } }
        view.width = width
        return view
    }

    func updateNSView(_ view: Strip, context: Context) {
        view.width = width
        view.window?.invalidateCursorRects(for: view)
    }
}
