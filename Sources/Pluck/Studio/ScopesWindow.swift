import AVFoundation
import CoreImage
import QuartzCore
import SwiftUI

// The Scopes window (layout reference, page 7): waveform, parade, vectorscope and histogram of what Photo
// or Edit shows, for a second screen. Finer than the small scopes elsewhere: a 1440 px copy in 16-bit
// Rec.709, 720 columns × 512 levels, a 512 × 512 vectorscope, the pictures drawn off the main thread.

/// One measured picture, ready to draw.
struct ScopeFrame: @unchecked Sendable {
    var luma: CGImage?
    var rgb: CGImage?
    var parade: CGImage?
    var vector: CGImage?
    /// Red, green and blue: how many samples at each of 256 levels.
    var histogram: [[Int]] = []
    /// The share of samples at the very top in any channel.
    var clipped = 0.0
}

enum ScopeRender {
    static let columns = 720
    static let levels = 512
    static let vectorSize = 512

    /// Measures a picture: shrunk to `columns × 2` wide, rendered as 16-bit Rec.709 code values.
    nonisolated static func frame(_ image: CIImage, context: CIContext) -> ScopeFrame? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, !extent.isInfinite,
              let space = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        let width = min(columns * 2, Int(extent.width))
        let scale = Double(width) / extent.width
        let height = max(1, min(Int((extent.height * scale).rounded()), width * 2))
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: width * 8,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA16, colorSpace: space)
        }
        return count(pixels, width: width, height: height)
    }

    private nonisolated static func count(_ pixels: [UInt16], width: Int, height: Int) -> ScopeFrame {
        let cols = min(columns, width), rows = levels, vsize = vectorSize
        var luma = [UInt32](repeating: 0, count: cols * rows)
        var red = luma, green = luma, blue = luma
        var vector = [UInt32](repeating: 0, count: vsize * vsize)
        var histR = [Int](repeating: 0, count: 256), histG = histR, histB = histR
        var top = 0
        let shift = 16 - 9 // 65536 levels → 512
        let half = Double(vsize) / 2, reach = Double(vsize - 2)
        pixels.withUnsafeBufferPointer { p in
            luma.withUnsafeMutableBufferPointer { l in
            red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
            blue.withUnsafeMutableBufferPointer { b in
            vector.withUnsafeMutableBufferPointer { v in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = (y * width + x) * 4
                        let rv = Int(p[i]), gv = Int(p[i + 1]), bv = Int(p[i + 2])
                        let base = (x * cols / width) * rows
                        let yv = (13933 * rv + 46871 * gv + 4732 * bv) >> 16 // Rec.709 weights × 65536
                        l[base + (yv >> shift)] &+= 1
                        r[base + (rv >> shift)] &+= 1
                        g[base + (gv >> shift)] &+= 1
                        b[base + (bv >> shift)] &+= 1
                        histR[rv >> 8] += 1; histG[gv >> 8] += 1; histB[bv >> 8] += 1
                        if rv >= 65400 || gv >= 65400 || bv >= 65400 { top += 1 }
                        // Cb and Cr (-0.5…0.5 of full scale) onto the grid; the middle is no colour.
                        let cb = Double(bv - yv) / 1.8556 / 65535, cr = Double(rv - yv) / 1.5748 / 65535
                        let vx = min(vsize - 1, max(0, Int((half + cb * reach).rounded())))
                        let vy = min(vsize - 1, max(0, Int((half + cr * reach).rounded())))
                        v[vy * vsize + vx] &+= 1
                    }
                }
            }}}}}
        }
        var frame = ScopeFrame()
        frame.luma = traces(width: cols, rows: rows, layers: [(luma, 0, (0.82, 0.92, 0.84))])
        frame.rgb = traces(width: cols, rows: rows, layers: [(red, 0, (1, 0.22, 0.22)), (green, 0, (0.25, 1, 0.3)), (blue, 0, (0.3, 0.45, 1))])
        frame.parade = traces(width: cols * 3, rows: rows, layers: [(red, 0, (1, 0.25, 0.25)), (green, cols, (0.3, 1, 0.3)), (blue, cols * 2, (0.35, 0.5, 1))])
        frame.vector = vectorPicture(vector, size: vsize)
        frame.histogram = [histR, histG, histB]
        frame.clipped = Double(top) / Double(max(width * height, 1))
        return frame
    }

    /// Waveform bins as a picture: each layer's columns from `offset`, the top row the brightest level,
    /// brightness log-scaled; layers add (red, green and blue meeting read white).
    private nonisolated static func traces(width: Int, rows: Int, layers: [([UInt32], Int, (Float, Float, Float))]) -> CGImage? {
        var values = [Float](repeating: 0, count: width * rows * 3)
        for (bins, offset, tint) in layers {
            let peak = Float(log1p(Double(bins.max() ?? 1)))
            guard peak > 0 else { continue }
            let cols = bins.count / rows
            for column in 0..<cols {
                for level in 0..<rows {
                    let count = bins[column * rows + level]
                    guard count > 0 else { continue }
                    let shade = min(1, max(0.14, Float(log1p(Double(count))) / peak))
                    let at = ((rows - 1 - level) * width + offset + column) * 3
                    values[at] += shade * tint.0; values[at + 1] += shade * tint.1; values[at + 2] += shade * tint.2
                }
            }
        }
        return image(values, width: width, height: rows)
    }

    private nonisolated static func vectorPicture(_ bins: [UInt32], size: Int) -> CGImage? {
        var values = [Float](repeating: 0, count: size * size * 3)
        let peak = Float(log1p(Double(bins.max() ?? 1)))
        if peak > 0 {
            for y in 0..<size {
                for x in 0..<size {
                    let count = bins[y * size + x]
                    guard count > 0 else { continue }
                    let shade = min(1, max(0.16, Float(log1p(Double(count))) / peak))
                    let at = ((size - 1 - y) * size + x) * 3
                    values[at] = shade * 0.9; values[at + 1] = shade * 0.95; values[at + 2] = shade * 0.9
                }
            }
        }
        return image(values, width: size, height: size)
    }

    private nonisolated static func image(_ values: [Float], width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            bytes[i * 4] = UInt8(min(255, values[i * 3] * 255))
            bytes[i * 4 + 1] = UInt8(min(255, values[i * 3 + 1] * 255))
            bytes[i * 4 + 2] = UInt8(min(255, values[i * 3 + 2] * 255))
        }
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }
}

/// What the Scopes window shows: the picture on the Photo page, or the frames of the Edit page's player.
@MainActor
@Observable
final class ScopeHub {
    static let shared = ScopeHub()

    enum Source { case photo, edit }

    private(set) var source: Source = .photo
    /// The file or project the scopes are of.
    private(set) var name = ""
    /// The window is open: only then is anything measured.
    var open = false { didSet { if !open { detachOutput() }; restartTimer(); measure() } }
    private(set) var frame: ScopeFrame?

    @ObservationIgnored private var photoImage: CIImage?
    @ObservationIgnored private var photoName = ""
    @ObservationIgnored private weak var player: AVPlayer?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private weak var outputItem: AVPlayerItem?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var editImage: CIImage?
    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])
    /// One measurement at a time; a picture that arrives meanwhile waits, and only the newest.
    @ObservationIgnored private var measuring = false
    @ObservationIgnored private var remeasure = false

    /// The Photo page shows this picture.
    func photoPicture(_ image: CIImage?, name: String) {
        photoImage = image
        photoName = name
        showPhoto()
    }

    func showPhoto() {
        source = .photo
        name = photoName
        restartTimer()
        measure()
    }

    /// The Edit page shows this player.
    func follow(_ player: AVPlayer, name: String) {
        if self.player !== player { editImage = nil; if source == .edit { frame = nil } }
        self.player = player
        source = .edit
        self.name = name
        restartTimer()
    }

    /// Measures what's shown, straight after each change, one at a time, the newest winning.
    private func measure() {
        guard open, let image = source == .photo ? photoImage : editImage else { return }
        guard !measuring else { remeasure = true; return }
        measuring = true
        let wanted = source
        Task {
            let measured = await Task.detached(priority: .userInitiated) { ScopeRender.frame(image, context: Self.context) }.value
            measuring = false
            if source == wanted { frame = measured }
            if remeasure { remeasure = false; measure() }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard open, source == .edit, player != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    /// Reads the frame on screen, if there's a new one.
    private func sample() {
        guard let player, let item = player.currentItem else { return }
        if outputItem !== item {
            if let output, let old = outputItem { old.remove(output) }
            let fresh = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(fresh)
            output = fresh
            outputItem = item
            // A paused item gives a new output no frame until it moves: the same place again, exactly.
            if player.rate == 0 { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        editImage = CIImage(cvPixelBuffer: buffer)
        measure()
    }

    /// The window closed: the player stops handing frames to it.
    private func detachOutput() {
        if let output, let outputItem { outputItem.remove(output) }
        output = nil
        outputItem = nil
    }
}

/// The scopes the window can show, in its order.
enum WindowScope: String, CaseIterable, Identifiable {
    case waveform, parade, vectorscope, histogram
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .waveform: "Waveform"
        case .parade: "Parade"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        }
    }
}

struct ScopesWindow: View {
    @State private var hub = ScopeHub.shared
    @AppStorage("scopesWindowCount") private var count = 4
    @AppStorage("scopesWindowKinds") private var kindsRaw = "waveform,parade,vectorscope,histogram"
    @AppStorage("scopesWaveformRGB") private var waveformRGB = false
    @Environment(\.dismissWindow) private var dismissWindow

    private var kinds: [WindowScope] {
        let chosen = kindsRaw.split(separator: ",").compactMap { WindowScope(rawValue: String($0)) }
        return chosen.count == 4 ? chosen : WindowScope.allCases
    }

    var body: some View {
        let shown = Array(kinds.prefix(count))
        let columns = count == 1 ? 1 : 2
        let rows = count == 4 ? 2 : 1
        VStack(spacing: 0) {
            header
            Grid(horizontalSpacing: Design.Studio.panelGap, verticalSpacing: Design.Studio.panelGap) {
                ForEach(0..<rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if index < shown.count { panel(index: index, kind: shown[index]) }
                        }
                    }
                }
            }
            .padding([.horizontal, .bottom], Design.Studio.panelGap)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 640, minHeight: 420)
        .background(Design.Studio.backdrop)
        .preferredColorScheme(.dark)
        .tint(Design.Brand.pink)
        .focusEffectDisabled()
        .onAppear { hub.open = true }
        .onDisappear { hub.open = false }
    }

    /// The 44 pt title row (the window has no title bar of its own): name, what it follows, 1 · 2 · 4, back.
    private var header: some View {
        HStack(spacing: 16) {
            Text("Scopes").foregroundStyle(Design.Studio.text)
            Text(hub.name.isEmpty ? String(localized: "Follows Photo and Edit") : String(localized: "\(hub.name) · follows Photo and Edit"))
                .foregroundStyle(Design.Studio.textQuiet)
                .lineLimit(1)
            Spacer(minLength: 8)
            StudioSegmented(ground: Design.Studio.panel, options: [(1, "1"), (2, "2"), (4, "4")], selection: $count)
                .help("How many scopes")
            Button { dismissWindow(id: "scopes") } label: {
                Label("Back into Pluck", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(StudioFlatButtonStyle())
            .help("Close the Scopes window: the scope stays over Photo's Adjust panel")
        }
        .font(Design.Studio.body)
        .padding(.leading, 86)
        .padding(.trailing, 14)
        .frame(height: 44)
    }

    /// One scope in its panel: the title (a menu to show another scope here), a note on the right, the scope.
    private func panel(index: Int, kind: WindowScope) -> some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(WindowScope.allCases) { other in
                        Button(other.title) { swap(index, to: other) }
                    }
                } label: {
                    Text(kind.title).font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Show another scope here")
                Spacer()
                note(kind)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            ScopeSurface(kind: kind, frame: hub.frame, rgb: waveformRGB)
                .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                .padding([.horizontal, .bottom], 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioPanel()
    }

    @ViewBuilder private func note(_ kind: WindowScope) -> some View {
        switch kind {
        case .waveform:
            Menu {
                Picker("Waveform", selection: $waveformRGB) {
                    Text("Luma").tag(false)
                    Text("RGB").tag(true)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Text(waveformRGB ? "RGB" : String(localized: "Luma"))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(Design.Studio.body)
                .foregroundStyle(Design.Studio.textQuiet)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        case .parade:
            Text(verbatim: "RGB").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        case .vectorscope:
            Text("Skin line on").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
        case .histogram:
            if let clipped = hub.frame?.clipped {
                Text("Clipped: \(clipped.formatted(.percent.precision(.fractionLength(1)))) highlights")
                    .font(Design.Studio.body)
                    .foregroundStyle(clipped > 0.001 ? Design.Studio.warn : Design.Studio.textQuiet)
            }
        }
    }

    /// Shows `kind` in panel `index`; the scope that was there takes the other's place.
    private func swap(_ index: Int, to kind: WindowScope) {
        var list = kinds
        guard let other = list.firstIndex(of: kind), other != index else { return }
        list.swapAt(index, other)
        kindsRaw = list.map(\.rawValue).joined(separator: ",")
    }
}

/// A scope drawn on near-black, with quiet grid lines.
private struct ScopeSurface: View {
    let kind: WindowScope
    let frame: ScopeFrame?
    let rgb: Bool
    private static let ground = Design.rgb(0x0B0B0D)

    var body: some View {
        switch kind {
        case .waveform:
            trace(rgb ? frame?.rgb : frame?.luma, thirds: false).overlay(alignment: .topLeading) { levels }
        case .parade:
            trace(frame?.parade, thirds: true)
        case .vectorscope:
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                if let picture = frame?.vector {
                    context.draw(Image(decorative: picture, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: size))
                }
                ScopesView.graticule(&context, size, .vectorscope)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Self.ground)
        case .histogram:
            histogram
        }
    }

    /// A waveform-type scope: the picture stretched to the panel, smooth, the 0–100 lines over it.
    private func trace(_ picture: CGImage?, thirds: Bool) -> some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            if let picture {
                context.draw(Image(decorative: picture, scale: 1).interpolation(.high), in: CGRect(origin: .zero, size: size))
            }
            var lines = Path()
            for percent in [0, 25, 50, 75, 100] as [CGFloat] {
                let y = min(max(size.height * (1 - percent / 100), 0.5), size.height - 0.5)
                lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            if thirds {
                for third in 1...2 {
                    let x = size.width * CGFloat(third) / 3
                    lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            context.stroke(lines, with: .color(.white.opacity(0.16)), lineWidth: 0.5)
        }
    }

    /// 100, 50 and 0 beside the waveform's lines.
    private var levels: some View {
        GeometryReader { geometry in
            ForEach([100, 50, 0], id: \.self) { level in
                Text(verbatim: "\(level)")
                    .font(Design.Studio.hint)
                    .foregroundStyle(Design.Studio.textQuiet)
                    .position(x: 16, y: min(max(geometry.size.height * (1 - CGFloat(level) / 100) - 8, 8), geometry.size.height - 8))
            }
        }
        .allowsHitTesting(false)
    }

    /// Red, green and blue histograms as soft areas, the clipped end marked on the right.
    private var histogram: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.ground))
            var grid = Path()
            for quarter in 1...3 {
                let x = size.width * CGFloat(quarter) / 4
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(Design.Studio.raised), lineWidth: 1)
            guard let frame, frame.histogram.count == 3 else { return }
            let tints = [Color(red: 0.85, green: 0.3, blue: 0.3), Color(red: 0.4, green: 0.8, blue: 0.4), Color(red: 0.4, green: 0.55, blue: 0.95)]
            let top = frame.histogram.map { $0.dropLast().dropFirst().max() ?? 1 }.max() ?? 1
            context.blendMode = .plusLighter
            for (counts, tint) in zip(frame.histogram, tints) {
                var area = Path()
                area.move(to: CGPoint(x: 0, y: size.height))
                for (level, count) in counts.enumerated() {
                    let x = size.width * CGFloat(level) / 255
                    let y = size.height * (1 - min(1, CGFloat(count) / CGFloat(max(top, 1))) * 0.92)
                    area.addLine(to: CGPoint(x: x, y: y))
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(tint.opacity(0.45)))
            }
            context.blendMode = .normal
            if frame.clipped > 0.001 {
                context.fill(Path(CGRect(x: size.width - 8, y: 0, width: 8, height: size.height)), with: .color(Design.Studio.warn.opacity(0.5)))
            }
        }
    }
}
