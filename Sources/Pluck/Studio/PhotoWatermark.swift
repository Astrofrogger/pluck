import AppKit
import CoreImage
import ImageIO

/// A mark laid over exported photos: a line of text or a logo, in one of nine places.
struct PhotoWatermark: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case text, image }
    enum Position: String, Codable, CaseIterable, Identifiable {
        case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
        var id: String { rawValue }
        /// 0 left, 1 middle, 2 right.
        var column: Int {
            switch self {
            case .topLeft, .left, .bottomLeft: 0
            case .top, .center, .bottom: 1
            case .topRight, .right, .bottomRight: 2
            }
        }
        /// 0 bottom, 1 middle, 2 top (the picture's origin is its lower left).
        var row: Int {
            switch self {
            case .bottomLeft, .bottom, .bottomRight: 0
            case .left, .center, .right: 1
            case .topLeft, .top, .topRight: 2
            }
        }
    }

    var kind = Kind.text
    var text = "© Northwind"
    var font = "Helvetica Neue"
    var imagePath: String?
    var position = Position.bottomRight
    /// The text's height, as a share of the photo's long side (a logo's long side is four times it).
    var size = 0.04
    var opacity = 0.7
    /// The distance from the edges, as a share of the long side.
    var margin = 0.02

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PhotoWatermark()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? d.kind
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? d.text
        font = try c.decodeIfPresent(String.self, forKey: .font) ?? d.font
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        position = try c.decodeIfPresent(Position.self, forKey: .position) ?? d.position
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? d.margin
    }

    /// Fonts offered in the menu (all of them are on every Mac).
    static let fonts = ["Helvetica Neue", "Avenir Next", "Georgia", "Baskerville", "Futura", "Gill Sans", "Menlo", "Didot"]

    /// Lays the mark over the photo; the picture keeps its extent.
    static func apply(_ image: CIImage, _ mark: PhotoWatermark) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, let made = render(mark, long: max(extent.width, extent.height), within: extent.size) else { return image }
        let long = max(extent.width, extent.height)
        let gap = (mark.margin * long).rounded()
        let width = CGFloat(made.width), height = CGFloat(made.height)
        // The shadow's padding is part of the picture, so the mark's edge lands on the margin.
        let x = extent.minX + gap + CGFloat(mark.position.column) * (extent.width - width - 2 * gap) / 2
        let y = extent.minY + gap + CGFloat(mark.position.row) * (extent.height - height - 2 * gap) / 2
        let layer = CIImage(cgImage: made).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        return layer.composited(over: image).cropped(to: extent)
    }

    // MARK: - Drawing

    /// The mark as a picture with a transparent background (opacity applied).
    private static func render(_ mark: PhotoWatermark, long: CGFloat, within bounds: CGSize) -> CGImage? {
        let height = max(8, (mark.size * long).rounded())
        switch mark.kind {
        case .text:
            let trimmed = mark.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            func styled(_ size: CGFloat) -> NSAttributedString {
                let font = NSFont(name: mark.font, size: size) ?? NSFont.systemFont(ofSize: size, weight: .medium)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
                shadow.shadowBlurRadius = size * 0.12
                shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
                return NSAttributedString(string: trimmed, attributes: [.font: font, .foregroundColor: NSColor.white, .shadow: shadow])
            }
            // A long line on a small photo is made smaller to fit inside its margins.
            var height = height
            var string = styled(height)
            let room = bounds.width - 2 * (mark.margin * long).rounded()
            let wanted = string.size().width + 2 * ceil(height * 0.2)
            if room > 0, wanted > room {
                height = max(4, (height * room / wanted).rounded(.down))
                string = styled(height)
            }
            let text = string.size()
            let pad = ceil(height * 0.2)
            let size = CGSize(width: ceil(text.width) + 2 * pad, height: ceil(text.height) + 2 * pad)
            return draw(size: size, opacity: mark.opacity) { string.draw(at: NSPoint(x: pad, y: pad)) }
        case .image:
            guard let path = mark.imagePath else { return nil }
            let longest = min(height * 4, max(bounds.width, bounds.height) * 0.9)
            guard let logo = logo(path, longest: Int(longest)) else { return nil }
            let scale = longest / CGFloat(max(logo.width, logo.height))
            let size = CGSize(width: max(1, (CGFloat(logo.width) * scale).rounded()), height: max(1, (CGFloat(logo.height) * scale).rounded()))
            return draw(size: size, opacity: mark.opacity) {
                NSGraphicsContext.current?.cgContext.draw(logo, in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private static func draw(size: CGSize, opacity: Double, _ body: () -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setAlpha(CGFloat(min(max(opacity, 0), 1)))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body()
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    nonisolated(unsafe) private static var logos: [String: CGImage] = [:]
    private static let lock = NSLock()

    /// The logo, scaled once to the size it's needed at and kept for the rest of the export.
    private static func logo(_ path: String, longest: Int) -> CGImage? {
        let key = "\(path)#\(longest)"
        lock.lock()
        if let known = logos[key] { lock.unlock(); return known }
        lock.unlock()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(longest, 8),
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        lock.lock()
        if logos.count > 8 { logos.removeAll() }
        logos[key] = image
        lock.unlock()
        return image
    }
}
