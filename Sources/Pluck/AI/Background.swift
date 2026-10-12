import AppKit
import CoreImage
import Vision

/// New Background: separates what matters from what's behind it, frame by frame, without a green
/// screen: people (Apple's person cutout), the main subject (subject lifting), or for graphics and
/// logo animations, the plain colour behind them. All local AI. The background is blurred, replaced
/// by a colour or picture, or made transparent for editing.
enum Background {
    /// What to keep.
    enum Keep: String, CaseIterable, Identifiable {
        case automatic, people, subject, plain
        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .people: String(localized: "People")
            case .subject: String(localized: "Main Subject")
            case .plain: String(localized: "All but a Plain Background")
            }
        }

        var detail: String {
            switch self {
            case .automatic: String(localized: "Pluck looks at the video: a plain background around a graphic or logo is taken out, otherwise it keeps the people, or the main subject.")
            case .people: String(localized: "Keeps the people in the picture.")
            case .subject: String(localized: "Keeps what stands out: a person, a product, an animal.")
            case .plain: String(localized: "For green screens: removes the one background colour everywhere, also between arms and inside letters.")
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case blur, color, image, transparent
        var id: String { rawValue }

        var label: String {
            switch self {
            case .blur: String(localized: "Blur")
            case .color: String(localized: "Colour")
            case .image: String(localized: "Picture")
            case .transparent: String(localized: "Transparent")
            }
        }

        var detail: String {
            switch self {
            case .blur: String(localized: "Keeps the room but softly out of focus, like a portrait lens.")
            case .color: String(localized: "A plain colour behind what’s kept.")
            case .image: String(localized: "A photo of your choice behind what’s kept.")
            case .transparent: String(localized: "No background at all: a ProRes 4444 file to place over other footage in your editor.")
            }
        }
    }

    struct Options {
        var kind: Kind = .blur
        var keep: Keep = .automatic
        /// RGB hex without "#", for `.color`.
        var color = "1C1C1E"
        /// The picture for `.image`.
        var image: URL?
    }

    static let swatches = ["1C1C1E", "FFFFFF", "0A84FF", "30D158", "FF5C6B"]

    /// The step that gives one frame its new background. With Automatic, the first frame decides
    /// how (and the rest of the video follows it, so the cut doesn't change half-way).
    final class Painter: @unchecked Sendable {
        private let options: Options
        private let people = VNGeneratePersonSegmentationRequest()
        private let sequence = VNSequenceRequestHandler()
        private var picture: CIImage?
        private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        /// How this video is cut, once decided.
        private(set) var method: Method?
        /// The colour cube that keys out a plain background.
        private var keyCube: Data?

        enum Method: Equatable {
            /// The video is transparent already: its own alpha.
            case ownAlpha
            /// A plain background in this colour (0…1 RGB); `everywhere` also takes it out inside
            /// the graphic (between arms on a green screen), otherwise only what runs to the edge.
            case plain(r: Float, g: Float, b: Float, everywhere: Bool)
            case people, subject
        }

        init(options: Options) {
            self.options = options
            people.qualityLevel = .balanced
            people.outputPixelFormat = kCVPixelFormatType_OneComponent8
            if options.kind == .image, let url = options.image { picture = CIImage(contentsOf: url) }
        }

        func paint(_ frame: CIImage) throws -> CIImage {
            let extent = frame.extent
            if method == nil { method = try decide(frame) }
            let kept: CIImage
            switch method ?? .people {
            case .ownAlpha:
                kept = frame
            case .plain(let r, let g, let b, let everywhere):
                if keyCube == nil { keyCube = Self.keyCube(r: r, g: g, b: b) }
                let keyed = frame.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": keyCube ?? Data()])
                if everywhere {
                    kept = keyed
                    break
                }
                // Only the background colour that runs to the edge of the picture goes; the same
                // colour inside the graphic (white letters on a white background) stays.
                kept = keyed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: frame,
                                                                            kCIInputMaskImageKey: outside(keyed)])
            case .people:
                guard let mask = try peopleMask(frame) else { return frame }
                kept = frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                                                                            kCIInputMaskImageKey: mask])
            case .subject:
                guard let mask = try subjectMask(frame) else { return frame }
                kept = frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
                                                                            kCIInputMaskImageKey: mask])
            }
            return kept.composited(over: background(extent, frame: frame)).cropped(to: extent)
        }

        private func background(_ extent: CGRect, frame: CIImage) -> CIImage {
            switch options.kind {
            case .blur:
                return frame.clampedToExtent().applyingGaussianBlur(sigma: extent.height / 45).cropped(to: extent)
            case .color:
                let (r, g, b) = Background.rgb(options.color)
                return CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: extent)
            case .image:
                guard let picture else { return CIImage(color: .clear).cropped(to: extent) }
                // Fill the frame, cropping the picture's overflow evenly.
                let scale = max(extent.width / picture.extent.width, extent.height / picture.extent.height)
                let scaled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return scaled.transformed(by: CGAffineTransform(translationX: (extent.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                y: (extent.height - scaled.extent.height) / 2 - scaled.extent.minY))
                    .cropped(to: extent)
            case .transparent:
                return CIImage(color: .clear).cropped(to: extent)
            }
        }

        // MARK: Deciding

        /// How to cut this video, from its first frame.
        private func decide(_ frame: CIImage) throws -> Method {
            let border = edgePixels(frame)
            switch options.keep {
            case .people: return .people
            case .subject: return .subject
            case .plain:
                guard case .plain(let r, let g, let b, _) = Self.plainColour(border) ?? .plain(r: 0, g: 1, b: 0, everywhere: true) else { return .people }
                return .plain(r: r, g: g, b: b, everywhere: true)
            case .automatic:
                // Transparent around the edges: it has its own alpha (a logo animation in ProRes 4444).
                if !border.isEmpty, border.filter({ $0.a < 0.1 }).count > border.count * 8 / 10 { return .ownAlpha }
                if let plain = Self.plainColour(border) { return plain }
                if let mask = try peopleMask(frame), coverage(mask) > 0.02 { return .people }
                return .subject
            }
        }

        private struct Pixel { var r: Float, g: Float, b: Float, a: Float }

        /// The pixels around the edge of a small copy of the frame.
        private func edgePixels(_ frame: CIImage) -> [Pixel] {
            let width = 96, height = 54
            let small = frame.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / frame.extent.width, y: CGFloat(height) / frame.extent.height))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(small, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: nil)
            var pixels: [Pixel] = []
            for y in 0..<height {
                for x in 0..<width where x < 3 || x >= width - 3 || y < 3 || y >= height - 3 {
                    let i = (y * width + x) * 4
                    let a = Float(bytes[i + 3]) / 255
                    // Un-premultiplied colour.
                    let scale = a > 0 ? 1 / (255 * a) : 0
                    pixels.append(Pixel(r: Float(bytes[i]) * scale, g: Float(bytes[i + 1]) * scale, b: Float(bytes[i + 2]) * scale, a: a))
                }
            }
            return pixels
        }

        /// The edge's colour when nearly all of it is one colour (a plain background), else nil.
        private static func plainColour(_ border: [Pixel]) -> Method? {
            guard !border.isEmpty else { return nil }
            func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }
            let r = median(border.map(\.r)), g = median(border.map(\.g)), b = median(border.map(\.b))
            let close = border.filter { abs($0.r - r) + abs($0.g - g) + abs($0.b - b) < 0.12 }.count
            return close > border.count * 85 / 100 ? .plain(r: r, g: g, b: b, everywhere: false) : nil
        }

        // MARK: Masks

        private func peopleMask(_ frame: CIImage) throws -> CIImage? {
            let extent = frame.extent
            try sequence.perform([people], on: frame)
            guard let buffer = people.results?.first?.pixelBuffer else { return nil }
            var mask = CIImage(cvPixelBuffer: buffer)
            mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            // A slightly soft edge reads as natural hair and shoulders, not a cut-out.
            return mask.clampedToExtent().applyingGaussianBlur(sigma: max(extent.height / 900, 1)).cropped(to: extent)
        }

        private func subjectMask(_ frame: CIImage) throws -> CIImage? {
            let extent = frame.extent
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: frame)
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
            var mask = CIImage(cvPixelBuffer: buffer)
            mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            return mask.clampedToExtent().applyingGaussianBlur(sigma: max(extent.height / 1200, 0.8)).cropped(to: extent)
        }

        /// How much of the picture a mask keeps (0…1).
        private func coverage(_ mask: CIImage) -> Double {
            var value = [UInt8](repeating: 0, count: 4)
            let average = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)])
            context.render(average, toBitmap: &value, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            return Double(value[0]) / 255
        }

        // MARK: Keying a plain colour

        /// Where the keyed-out colour is connected to the edge of the picture (white there), at a
        /// working size, grown a little so soft edges are included, then smoothed back up.
        private func outside(_ keyed: CIImage) -> CIImage {
            let extent = keyed.extent
            let width = min(640, Int(extent.width)), height = max(1, Int((Double(width) * extent.height / extent.width).rounded()))
            let small = keyed.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            context.render(small, toBitmap: &bytes, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: nil)
            // Background: mostly transparent after keying. Fill from every edge pixel that is.
            var region = [UInt8](repeating: 0, count: width * height)
            var stack: [Int] = []
            func push(_ index: Int) {
                guard region[index] == 0, bytes[index * 4 + 3] < 160 else { return }
                region[index] = 255
                stack.append(index)
            }
            for x in 0..<width { push(x); push((height - 1) * width + x) }
            for y in 0..<height { push(y * width); push(y * width + width - 1) }
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                if x > 0 { push(index - 1) }
                if x < width - 1 { push(index + 1) }
                if y > 0 { push(index - width) }
                if y < height - 1 { push(index + width) }
            }
            // Grow by two pixels, so the soft edge between background and graphic is keyed too.
            var grown = region
            for _ in 0..<2 {
                let before = grown
                for y in 0..<height {
                    for x in 0..<width where before[y * width + x] == 0 {
                        let i = y * width + x
                        if (x > 0 && before[i - 1] > 0) || (x < width - 1 && before[i + 1] > 0)
                            || (y > 0 && before[i - width] > 0) || (y < height - 1 && before[i + width] > 0) {
                            grown[i] = 255
                        }
                    }
                }
            }
            let data = Data(grown)
            let mask = CIImage(bitmapData: data, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
            return mask.samplingLinear()
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
                .cropped(to: extent)
        }

        static let cubeSize = 64

        /// A colour cube that makes colours near the key transparent, softly, so anti-aliased
        /// edges and glows fade out instead of keeping a fringe.
        static func keyCube(r keyR: Float, g keyG: Float, b keyB: Float) -> Data {
            let size = cubeSize
            var cube = [Float](repeating: 0, count: size * size * size * 4)
            let inner: Float = 0.10, outer: Float = 0.28
            var i = 0
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let rf = Float(r) / Float(size - 1), gf = Float(g) / Float(size - 1), bf = Float(b) / Float(size - 1)
                        let distance = ((rf - keyR) * (rf - keyR) + (gf - keyG) * (gf - keyG) + (bf - keyB) * (bf - keyB)).squareRoot()
                        let t = min(max((distance - inner) / (outer - inner), 0), 1)
                        let alpha = t * t * (3 - 2 * t)
                        // Take the key colour out of the half-transparent edge, so it doesn't tint it.
                        func clean(_ c: Float, _ k: Float) -> Float { alpha > 0.001 ? min(max((c - k * (1 - alpha)) / alpha, 0), 1) : 0 }
                        cube[i] = clean(rf, keyR) * alpha
                        cube[i + 1] = clean(gf, keyG) * alpha
                        cube[i + 2] = clean(bf, keyB) * alpha
                        cube[i + 3] = alpha
                        i += 4
                    }
                }
            }
            return cube.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let value = Int(hex, radix: 16) ?? 0
        return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }
}

extension AIStudio {
    /// Makes a "(new background)" copy next to the video.
    func replaceBackground(_ item: DownloadItem, options: Background.Options) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Finding what to keep…")
            item.aiProgress = 0
            let transparent = options.kind == .transparent
            let picture = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-background-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: picture) }
            do {
                let painter = Background.Painter(options: options)
                try await Task.detached(priority: .userInitiated) {
                    try await FrameRewriter().run(input: file, output: picture, codec: transparent ? .proRes4444 : .hevc) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    } edit: { frame in
                        try painter.paint(frame.image)
                    }
                }.value

                item.aiStatus = String(localized: "Saving…")
                item.aiProgress = nil
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (new background)"),
                                                  fileExtension: transparent ? "mov" : "mp4")
                var args = ["-y", "-v", "error", "-i", picture.path, "-i", file.path, "-map", "0:v", "-map", "1:a?",
                            "-c:v", "copy", "-shortest"]
                args += transparent ? ["-c:a", "pcm_s16le"] : ["-c:a", "copy", "-tag:v", "hvc1", "-movflags", "+faststart"]
                try await ffmpeg(args + [output.path], failure: FrameRewriter.Failure.noVideo)
                finishJob(item)
                notify(title: String(localized: "“\(item.title)” has a new background"),
                       body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }
}
