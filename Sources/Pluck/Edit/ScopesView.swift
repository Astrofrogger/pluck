import SwiftUI

/// The scope drawn: log-scaled brightness on black, with lines at 0, 25, 50, 75 and 100 %, and the
/// 75 % colour targets on the vectorscope.
struct ScopesView: View {
    let data: ScopeData?
    let kind: ScopeKind

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            if let data, let picture = Self.picture(data, kind) {
                context.draw(Image(decorative: picture, scale: 1), in: CGRect(origin: .zero, size: size))
            }
            Self.graticule(&context, size, kind)
        }
        .aspectRatio(kind == .vectorscope ? 1 : 16.0 / 9, contentMode: .fit)
        .clipShape(.rect(cornerRadius: Design.Radius.small))
        .accessibilityHidden(true)
    }

    /// The bins as a picture (one pixel a bin, the top is 255), log-scaled to the fullest bin.
    static func picture(_ data: ScopeData, _ kind: ScopeKind) -> CGImage? {
        let total = kind == .parade ? data.width * 3 : kind == .vectorscope ? 256 : data.width
        var bytes = [UInt8](repeating: 0, count: total * 256 * 4)
        func paint(_ bins: [UInt16], x0: Int, columns: Int, rows: Int, tint: (r: Float, g: Float, b: Float), vector: Bool = false) {
            let top = Float(log(1 + Double(bins.max() ?? 1)))
            guard top > 0 else { return }
            for column in 0..<columns {
                for code in 0..<rows {
                    let count = vector ? bins[code * 256 + column] : bins[column * 256 + code]
                    guard count > 0 else { continue }
                    let level = min(1, max(0.12, Float(log(1 + Double(count))) / top))
                    let at = ((255 - code) * total + x0 + column) * 4
                    bytes[at] = UInt8(min(255, Float(255) * level * tint.r))
                    bytes[at + 1] = UInt8(min(255, Float(255) * level * tint.g))
                    bytes[at + 2] = UInt8(min(255, Float(255) * level * tint.b))
                    bytes[at + 3] = 255
                }
            }
        }
        switch kind {
        case .waveform: paint(data.luma, x0: 0, columns: data.width, rows: 256, tint: (0.85, 0.95, 0.85))
        case .parade:
            paint(data.red, x0: 0, columns: data.width, rows: 256, tint: (1, 0.25, 0.25))
            paint(data.green, x0: data.width, columns: data.width, rows: 256, tint: (0.3, 1, 0.3))
            paint(data.blue, x0: data.width * 2, columns: data.width, rows: 256, tint: (0.35, 0.5, 1))
        case .vectorscope: paint(data.vector, x0: 0, columns: 256, rows: 256, tint: (0.9, 0.95, 0.9), vector: true)
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: total, height: 256, bitsPerComponent: 8, bytesPerRow: total * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func graticule(_ context: inout GraphicsContext, _ size: CGSize, _ kind: ScopeKind) {
        let line = Color.white.opacity(0.28)
        if kind == .vectorscope {
            let centre = CGPoint(x: size.width / 2, y: size.height / 2), scale = size.width / 256
            for radius in [0.25, 0.5] as [Double] {
                let r = radius * 255 * scale
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)), with: .color(line), lineWidth: 0.5)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: 0, y: centre.y)); cross.addLine(to: CGPoint(x: size.width, y: centre.y))
            cross.move(to: CGPoint(x: centre.x, y: 0)); cross.addLine(to: CGPoint(x: centre.x, y: size.height))
            context.stroke(cross, with: .color(line), lineWidth: 0.5)
            // The 75 % targets: red, magenta, blue, cyan, green, yellow.
            for target in targets {
                let p = ScopeAnalyzer.vectorPoint(red: target.0 * 0.75, green: target.1 * 0.75, blue: target.2 * 0.75)
                let box = CGRect(x: p.cb * scale - 3.5, y: (255 - p.cr) * scale - 3.5, width: 7, height: 7)
                context.stroke(Path(box), with: .color(Color(red: target.0, green: target.1, blue: target.2).opacity(0.9)), lineWidth: 1)
            }
        } else {
            var lines = Path()
            for percent in [0, 25, 50, 75, 100] as [Double] {
                let y = size.height * (1 - percent / 100)
                lines.move(to: CGPoint(x: 0, y: min(max(y, 0.25), size.height - 0.25)))
                lines.addLine(to: CGPoint(x: size.width, y: min(max(y, 0.25), size.height - 0.25)))
            }
            context.stroke(lines, with: .color(line), lineWidth: 0.5)
        }
    }

    private static let targets: [(Double, Double, Double)] = [(1, 0, 0), (1, 0, 1), (0, 0, 1), (0, 1, 1), (0, 1, 0), (1, 1, 0)]
}

/// The scope of what a ScopeFeed last analysed. Its own view, so the 12 updates a second redraw only this
/// and not the page around it.
struct LiveScopesView: View {
    let feed: ScopeFeed
    let kind: ScopeKind

    var body: some View { ScopesView(data: feed.data, kind: kind) }
}
