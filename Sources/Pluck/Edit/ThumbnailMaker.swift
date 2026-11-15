import AVFoundation
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Thumbnail Maker: the best frames of a video (sharp, exposed, eyes open, a subject placed well,
/// never black, blurred or mid-transition), and a thumbnail drawn on one in the brand's style.
enum ThumbnailMaker {
    // MARK: - Frames

    /// A frame looked at: its picture (about 640 px), how good a thumbnail it would make, and why
    /// not when it can't be one.
    struct Sample: Identifiable {
        var time: Double
        var image: CGImage
        var score: Double
        /// The subject's centre (faces, else what stands out), shares from the top left.
        var focus: CGPoint
        var faces: Int
        var eyesOpen: Bool
        /// Which shot it's in (between hard cuts).
        var scene: Int
        /// Black, soft, transition, cut: why it's left out (empty: it can be picked).
        var rejected: [String]
        /// Edge detail, to compare with the video's sharpest frames.
        var sharpness = 0.0
        var id: Double { time }
    }

    /// Every frame looked at (rejected ones too, with why), in time order.
    static func samples(_ file: URL, ffmpeg: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Sample] {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.2, let track = try await asset.loadTracks(withMediaType: .video).first else { throw VisualIndex.Failure.noVideo }
        let fps = Double(try await track.load(.nominalFrameRate))
        // Transitions someone made (dissolves, fades, whip pans) from Delivery Check, and the hard cuts.
        let picture = await DeliveryCheck.picture(file, fps: fps > 0 ? fps : 25, duration: duration, ffmpeg: ffmpeg) { progress($0 * 0.4) }
        let cuts = await Shorts.cuts(in: file, from: 0, to: duration, ffmpeg: ffmpeg).sorted()
        // About 150 looks spread over the video, and one just after each cut so every shot has some.
        let step = max(0.25, duration / 150)
        var times = Array(stride(from: step / 2, to: duration, by: step))
        times += cuts.map { $0 + 0.4 }.filter { $0 < duration }
        times.sort()

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)

        var samples: [Sample] = []
        for (n, time) in times.enumerated() {
            try Task.checkCancellation()
            progress(0.4 + 0.6 * Double(n) / Double(max(times.count, 1)))
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            var sample = look(at: image, time: time)
            sample.scene = cuts.filter { $0 <= time }.count
            // (A dissolve's faint ends aren't found as part of it: a quarter second more either side.)
            if picture.transitions.contains(where: { time >= $0.start - 0.25 && time <= $0.end + 0.25 }) { sample.rejected.append("transition") }
            if cuts.contains(where: { abs($0 - time) < 0.15 }) { sample.rejected.append("cut") }
            samples.append(sample)
        }
        // Soft compared with this video's sharpest frames too (a camera's own softness isn't blur).
        let sharpest = samples.map(\.sharpness).sorted(by: >).dropFirst(samples.count / 10).first ?? 0
        for i in samples.indices where sharpest > 0 && samples[i].sharpness < sharpest * 0.15 && !samples[i].rejected.contains("soft") {
            samples[i].rejected.append("soft")
        }
        progress(1)
        return samples
    }

    /// The best `count` frames, one per shot first, then others that don't look alike; the best first.
    static func pick(_ samples: [Sample], count: Int = 12) -> [Sample] {
        var usable = samples.filter(\.rejected.isEmpty)
        // Nothing clean at all: anything that isn't black, rather than nothing.
        if usable.isEmpty { usable = samples.filter { !$0.rejected.contains("black") } }
        let ranked = usable.sorted { $0.score > $1.score }
        var chosen: [Sample] = []
        var scenes = Set<Int>()
        for sample in ranked where chosen.count < count && !scenes.contains(sample.scene) {
            chosen.append(sample)
            scenes.insert(sample.scene)
        }
        let prints = Dictionary(ranked.compactMap { s in VisualIndex.featurePrint(s.image).map { (s.time, $0) } }, uniquingKeysWith: { a, _ in a })
        for sample in ranked where chosen.count < count && !chosen.contains(where: { $0.time == sample.time }) {
            let alike = chosen.contains { other in
                guard abs(other.time - sample.time) >= 1 else { return true }
                guard let a = prints[sample.time], let b = prints[other.time] else { return false }
                var distance: Float = 1
                try? a.computeDistance(&distance, to: b)
                return distance < 0.45
            }
            if !alike { chosen.append(sample) }
        }
        return chosen.sorted { $0.score > $1.score }
    }

    static func candidates(_ file: URL, ffmpeg: String, count: Int = 12, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Sample] {
        pick(try await samples(file, ffmpeg: ffmpeg, progress: progress), count: count)
    }

    /// One frame's score: usable (sharp, exposed) times interesting (faces with open eyes looking
    /// at us, an expression, Vision's aesthetics, the subject on a third).
    static func look(at image: CGImage, time: Double) -> Sample {
        let m = VisualIndex.measure(image)
        let landmarks = VNDetectFaceLandmarksRequest(), quality = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image).perform([landmarks, quality])
        let faces = (landmarks.results ?? []).filter { $0.boundingBox.height > 0.05 }
        let best = Double((quality.results ?? []).compactMap(\.faceCaptureQuality).max() ?? 0)
        let open = faces.allSatisfy { face in
            guard let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye else { return true }
            return PhotoChecks.openness(l) >= 0.16 || PhotoChecks.openness(r) >= 0.16
        }
        let facing = faces.contains { abs($0.yaw?.doubleValue ?? 0) < 0.35 }
        let expressive = faces.contains { face in face.landmarks?.outerLips.map { PhotoChecks.openness($0) > 0.3 } ?? false }
        // Where the subject is (Vision boxes have y up).
        var box = faces.map(\.boundingBox).reduce(nil) { (sum: CGRect?, b: CGRect) in sum?.union(b) ?? b }
        if box == nil { box = PhotoChecks.subjectBox(image) }
        let focus = box.map { CGPoint(x: $0.midX, y: 1 - $0.midY) } ?? CGPoint(x: 0.5, y: 0.5)
        let thirds = [CGPoint(x: 1 / 3.0, y: 1 / 3.0), CGPoint(x: 2 / 3.0, y: 1 / 3.0), CGPoint(x: 1 / 3.0, y: 2 / 3.0), CGPoint(x: 2 / 3.0, y: 2 / 3.0)]
        let off = thirds.map { hypot($0.x - focus.x, $0.y - focus.y) }.min() ?? 0
        let placed = box == nil ? 0 : max(0, 1 - Double(off) / 0.33)

        var rejected: [String] = []
        if m.brightness < 0.08 || m.crushed > 0.6 { rejected.append("black") }
        let sharpShare = min(1, max(0, (m.focus - 0.6) / 0.25))
        if sharpShare < 0.35 { rejected.append("soft") }
        var usable = 0.55 + 0.45 * sharpShare
        if m.blown > 0.25 { usable *= 0.6 }
        usable *= 1 - min(0.5, abs(m.brightness - 0.45))
        var interest = 0.3 + 0.25 * max(0, VisualIndex.aesthetics(of: image)) + 0.1 * placed
        if !faces.isEmpty {
            interest += 0.2 + 0.15 * best
            interest += open ? 0.1 : -0.2
            if facing { interest += 0.05 }
            if expressive { interest += 0.05 }
        }
        return Sample(time: time, image: image, score: usable * interest, focus: focus, faces: faces.count, eyesOpen: open,
                      scene: 0, rejected: rejected, sharpness: m.sharpness)
    }

    /// The video's frame at full size, for drawing the thumbnail.
    static func frame(_ file: URL, at time: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
    }

    // MARK: - Design

    enum Layout: String, CaseIterable, Identifiable {
        case bigTitle, titleSubtitle, split, cornerLogo, cutOut
        var id: String { rawValue }
        var name: LocalizedStringResource {
            switch self {
            case .bigTitle: "Big title"
            case .titleSubtitle: "Title and subtitle"
            case .split: "Split"
            case .cornerLogo: "Corner logo"
            case .cutOut: "Cut-out"
            }
        }
        var symbol: String {
            switch self {
            case .bigTitle: "textformat.size"
            case .titleSubtitle: "text.alignleft"
            case .split: "rectangle.split.2x1"
            case .cornerLogo: "seal"
            case .cutOut: "person.crop.rectangle"
            }
        }
    }

    /// Where it's shown, with the part its player or app covers kept free of text (shares of the size).
    enum Size: String, CaseIterable, Identifiable {
        case youtube, hd, vertical, portrait, square
        var id: String { rawValue }
        var pixels: CGSize {
            switch self {
            case .youtube: CGSize(width: 1280, height: 720)
            case .hd: CGSize(width: 1920, height: 1080)
            case .vertical: CGSize(width: 1080, height: 1920)
            case .portrait: CGSize(width: 1080, height: 1350)
            case .square: CGSize(width: 1080, height: 1080)
            }
        }
        var name: LocalizedStringResource {
            switch self {
            case .youtube: "YouTube"
            case .hd: "1080p"
            case .vertical: "Shorts and Reels"
            case .portrait: "Feed 4:5"
            case .square: "Square"
            }
        }
        /// Text and logos stay inside: YouTube's time stamp sits bottom right, Shorts and Reels cover
        /// the top, the bottom and the buttons on the right, a profile grid crops 4:5 to 3:4.
        var safe: (left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
            switch self {
            case .youtube: (0.05, 0.07, 0.05, 0.14)
            case .hd: (0.05, 0.05, 0.05, 0.08)
            case .vertical: (0.06, 0.14, 0.16, 0.30)
            case .portrait: (0.07, 0.06, 0.07, 0.06)
            case .square: (0.06, 0.06, 0.06, 0.06)
            }
        }
        func safeRect(_ canvas: CGSize) -> CGRect {
            let s = safe
            return CGRect(x: canvas.width * s.left, y: canvas.height * s.top,
                          width: canvas.width * (1 - s.left - s.right), height: canvas.height * (1 - s.top - s.bottom))
        }
    }

    /// The brand's look for a thumbnail: colours in roles, the title font, the logo.
    struct Brand {
        var palette: BrandPalette
        var font: String
        var logo: CGImage?

        @MainActor static var kit: Brand { Brand(palette: BrandKit.shared.palette, font: BrandKit.shared.style.titleFont, logo: nil) }

        @MainActor init(profile: BrandProfile?) {
            guard let profile else { self = .kit; return }
            let colours = profile.palette.compactMap { $0.hex.flatMap(BrandProfile.rgb(hex:)) }.map { MotionColor(r: $0.x, g: $0.y, b: $0.z) }
            self.init(palette: colours.isEmpty ? BrandKit.shared.palette : BrandPalette(colours: colours),
                      font: profile.fonts.first ?? BrandKit.shared.style.titleFont,
                      logo: profile.logos.first.flatMap { BrandProfile.image(of: $0) })
        }

        init(palette: BrandPalette, font: String, logo: CGImage?) {
            self.palette = palette; self.font = font; self.logo = logo
        }
    }

    struct Design: Hashable {
        var layout = Layout.bigTitle
        var title = ""
        var subtitle = ""
        /// −1 … 1 stops.
        var exposure = 0.0
        /// −1 … 1.
        var saturation = 0.0
        /// 0 … 1.
        var sharpen = 0.0
        /// 0 … 1.
        var vignette = 0.0
    }

    struct Rendered {
        var image: CGImage
        /// The lowest contrast of any text with what's behind it (WCAG ratio; 21 when there's no text).
        var contrast: Double
    }

    /// Text needs this contrast with what's behind it (WCAG AA for normal text).
    static let minimumContrast = 4.5

    // MARK: - Drawing

    /// The thumbnail at `canvas` pixels: the frame (enhanced, cropped round its subject), the
    /// layout's shapes, the title in the brand's font and colours (contrast checked), the logo.
    static func render(_ frame: CGImage, focus: CGPoint, design: Design, brand: Brand, size: Size, canvas: CGSize? = nil) -> Rendered? {
        let canvas = canvas ?? size.pixels
        let w = Int(canvas.width.rounded()), h = Int(canvas.height.rounded())
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(origin: .zero, size: canvas)
        let safe = size.safeRect(canvas)
        let palette = brand.palette
        let picture = enhanced(CIImage(cgImage: frame), design)
        // Layout rects are from the top left; Core Graphics draws from the bottom left.
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: canvas.height - r.maxY, width: r.width, height: r.height) }
        let tall = canvas.height > canvas.width

        // The picture, and where the text goes.
        var pictureRect = full
        var textBox = CGRect(x: safe.minX, y: safe.minY + safe.height * 0.5, width: safe.width, height: safe.height * 0.5)
        var person: CGImage?
        switch design.layout {
        case .split:
            let panel = tall ? CGRect(x: 0, y: canvas.height * 0.58, width: canvas.width, height: canvas.height * 0.42)
                             : CGRect(x: 0, y: 0, width: canvas.width * 0.42, height: canvas.height)
            pictureRect = tall ? CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * 0.58)
                               : CGRect(x: panel.maxX, y: 0, width: canvas.width - panel.maxX, height: canvas.height)
            context.setFillColor(palette.dark.cg)
            context.fill(flip(panel))
            textBox = panel.intersection(safe).insetBy(dx: canvas.width * 0.02, dy: canvas.height * 0.02)
        case .cutOut:
            // Beside the person (above them when tall), so they don't cover the title.
            textBox = tall ? CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: safe.height * 0.4)
                           : CGRect(x: focus.x >= 0.5 ? safe.minX : safe.midX, y: safe.minY, width: safe.width * 0.5, height: safe.height)
        case .cornerLogo:
            textBox = CGRect(x: safe.minX, y: safe.maxY - safe.height * 0.3, width: safe.width * 0.7, height: safe.height * 0.3)
        case .bigTitle, .titleSubtitle:
            break
        }
        let cropped = aspectFill(picture, into: pictureRect.size, focus: focus)
        if design.layout == .cutOut, let mask = personMask(cropped) {
            // The person sharp in front; the rest blurred and darkened behind the title.
            let back = cropped.clampedToExtent().applyingGaussianBlur(sigma: Double(canvas.width) * 0.012).cropped(to: cropped.extent)
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
            draw(back, in: flip(pictureRect), context)
            person = ciContext.createCGImage(cropped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: cropped.extent), kCIInputMaskImageKey: mask]), from: cropped.extent)
        } else {
            draw(cropped, in: flip(pictureRect), context)
        }
        // A darkening towards the text so it reads on any picture.
        if design.layout == .bigTitle || design.layout == .titleSubtitle {
            let from = canvas.height * 0.4
            let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [palette.dark.alpha(0), palette.dark.alpha(0.88)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(shade, start: CGPoint(x: 0, y: canvas.height - from), end: .zero, options: [.drawsAfterEndLocation])
        }

        // The texts, each checked against what's behind it.
        let title = design.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = design.layout == .titleSubtitle || design.layout == .split ? design.subtitle.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var lowest = 21.0
        let short = min(canvas.width, canvas.height)
        let titleSize: CGFloat = switch design.layout {
        case .bigTitle, .cutOut: short * 0.2
        case .titleSubtitle, .split: short * 0.14
        case .cornerLogo: short * 0.08
        }
        let maxLines = design.layout == .cornerLogo ? 1 : (design.layout == .cutOut ? 2 : 3)
        if !title.isEmpty || !subtitle.isEmpty {
            let titleFont = fitted(title.isEmpty ? " " : title, font: brand.font, size: titleSize, width: textBox.width, lines: maxLines)
            let titleText = NSAttributedString(string: title, attributes: [.font: titleFont])
            let titleHeight = title.isEmpty ? 0 : ceil(titleText.boundingRect(with: CGSize(width: textBox.width, height: .greatestFiniteMagnitude),
                                                                               options: [.usesLineFragmentOrigin]).height)
            let subFont = fitted(subtitle.isEmpty ? " " : subtitle, font: brand.font, size: titleFont.pointSize * 0.45, width: textBox.width, lines: 2, bold: false)
            let subHeight = subtitle.isEmpty ? 0 : ceil(NSAttributedString(string: subtitle, attributes: [.font: subFont])
                .boundingRect(with: CGSize(width: textBox.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
            let gap = subtitle.isEmpty || title.isEmpty ? 0 : subFont.pointSize * 0.5
            let block = titleHeight + gap + subHeight
            // Bottom of the box (top for the cut-out, middle for the split panel).
            let top: CGFloat = switch design.layout {
            case .cutOut: tall ? textBox.minY : textBox.midY - block / 2
            case .split: textBox.midY - block / 2
            default: textBox.maxY - block
            }
            let titleRect = CGRect(x: textBox.minX, y: top, width: textBox.width, height: titleHeight)
            let subRect = CGRect(x: textBox.minX, y: top + titleHeight + gap, width: textBox.width, height: subHeight)
            // The corner layout's title sits on a brand plate.
            var titleWidth = textBox.width
            if design.layout == .cornerLogo, !title.isEmpty {
                titleWidth = min(textBox.width, ceil(titleText.size().width))
                let pad = titleFont.pointSize * 0.35
                context.setFillColor(palette.primary.cg)
                context.addPath(CGPath(roundedRect: flip(CGRect(x: titleRect.minX - pad, y: titleRect.minY - pad * 0.6, width: titleWidth + pad * 2,
                                                                height: titleHeight + pad * 1.2)), cornerWidth: pad, cornerHeight: pad, transform: nil))
                context.fillPath()
            }
            let base = design.layout == .cornerLogo ? palette.primary.ink : (design.layout == .cutOut ? palette.light : palette.light)
            let accent = design.layout == .cutOut ? palette.primary : palette.secondary
            var items: [(text: String, font: NSFont, rect: CGRect, colour: MotionColor)] = []
            if !title.isEmpty { items.append((title, titleFont, CGRect(x: titleRect.minX, y: titleRect.minY, width: titleWidth, height: titleRect.height), design.layout == .cutOut ? accent : base)) }
            if !subtitle.isEmpty { items.append((subtitle, subFont, subRect, design.layout == .split ? accent : base)) }
            for item in items {
                guard let ground = average(context, item.rect) else { continue }
                var colour = item.colour.readable(on: ground, minimumContrast)
                var ratio = colour.contrast(ground)
                if ratio < minimumContrast {
                    // A busy or mid-grey picture: a plate of the brand's dark behind the text.
                    let pad = item.font.pointSize * 0.25
                    context.setFillColor(palette.dark.alpha(0.85))
                    context.fill(flip(item.rect.insetBy(dx: -pad, dy: -pad * 0.5)))
                    let plate = average(context, item.rect) ?? palette.dark
                    colour = item.colour.readable(on: plate, minimumContrast)
                    ratio = colour.contrast(plate)
                }
                lowest = min(lowest, ratio)
                text(item.text, font: item.font, colour: colour, in: flip(item.rect), context)
            }
        }
        if let person { context.draw(person, in: flip(pictureRect)) }
        // The logo: big in the corner layout, small on the split panel.
        if let logo = brand.logo, design.layout == .cornerLogo || design.layout == .split {
            let width = (design.layout == .cornerLogo ? 0.16 : 0.1) * canvas.width * (tall ? 1.6 : 1)
            let height = width * CGFloat(logo.height) / CGFloat(max(logo.width, 1))
            let rect = design.layout == .cornerLogo ? CGRect(x: safe.maxX - width, y: safe.minY, width: width, height: height)
                                                     : CGRect(x: textBox.minX, y: textBox.maxY - height, width: width, height: height)
            context.draw(logo, in: flip(rect))
        }
        guard let image = context.makeImage() else { return nil }
        return Rendered(image: image, contrast: lowest)
    }

    /// The gentle enhancements: exposure, saturation, sharpening, a vignette.
    static func enhanced(_ image: CIImage, _ d: Design) -> CIImage {
        var out = image
        if d.exposure != 0 { out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: d.exposure]) }
        if d.saturation != 0 { out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + d.saturation]) }
        if d.sharpen > 0 { out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: d.sharpen, kCIInputRadiusKey: 1.5]) }
        if d.vignette > 0 {
            let radius = max(image.extent.width, image.extent.height) * 0.6
            out = out.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: image.extent.midX, y: image.extent.midY),
                                                                       kCIInputRadiusKey: radius, kCIInputIntensityKey: d.vignette, "inputFalloff": 0.6])
        }
        return out.cropped(to: image.extent)
    }

    /// The picture scaled to cover `size`, the crop kept round the subject (focus from the top left).
    static func aspectFill(_ image: CIImage, into size: CGSize, focus: CGPoint) -> CIImage {
        let e = image.extent
        let k = max(size.width / e.width, size.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: k, y: k)))
        let sw = e.width * k, sh = e.height * k
        let x = min(max(focus.x * sw - size.width / 2, 0), sw - size.width)
        // (Core Image's y is up.)
        let yTop = min(max(focus.y * sh - size.height / 2, 0), sh - size.height)
        let y = sh - yTop - size.height
        return scaled.cropped(to: CGRect(x: x, y: y, width: size.width, height: size.height))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    nonisolated(unsafe) private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private static func draw(_ image: CIImage, in rect: CGRect, _ context: CGContext) {
        guard let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return }
        context.draw(cg, in: rect)
    }

    /// The person (Vision's person segmentation) as a mask the size of the picture, or nil when there's no one.
    static func personMask(_ image: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        // Hardly any person: no cut-out.
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mask.extent)]),
                         toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        guard pixel[0] > 5 else { return nil }
        let e = image.extent
        return mask.transformed(by: CGAffineTransform(scaleX: e.width / mask.extent.width, y: e.height / mask.extent.height)
            .concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
    }

    /// The average colour already drawn in a rect (from the top left).
    /// shortcut: the mean colour, so text over a busy picture may read worse than its ratio; measure the darkest/lightest tenth if that shows.
    static func average(_ context: CGContext, _ rect: CGRect) -> MotionColor? {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = context.width, h = context.height, row = context.bytesPerRow
        let x0 = max(0, Int(rect.minX)), x1 = min(w, Int(rect.maxX)), y0 = max(0, Int(rect.minY)), y1 = min(h, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                let p = y * row + x * 4
                r += Double(data[p]); g += Double(data[p + 1]); b += Double(data[p + 2]); n += 1
            }
        }
        return MotionColor(r: r / n / 255, g: g / n / 255, b: b / n / 255)
    }

    /// The brand's font in bold (or as named), else the system's heavy.
    static func font(_ name: String, size: CGFloat, bold: Bool = true) -> NSFont {
        if bold, let f = NSFontManager.shared.font(withFamily: name, traits: .boldFontMask, weight: 9, size: size) { return f }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .heavy : .medium)
    }

    /// The biggest size up to `size` at which the text fits `width` in `lines` lines.
    static func fitted(_ text: String, font name: String, size: CGFloat, width: CGFloat, lines: Int, bold: Bool = true) -> NSFont {
        var s = size
        while s > 10 {
            let f = font(name, size: s, bold: bold)
            let height = NSAttributedString(string: text, attributes: [.font: f])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
            // (One word wider than the line wraps mid-word: smaller too.)
            let widest = text.split(separator: " ").map { NSAttributedString(string: String($0), attributes: [.font: f]).size().width }.max() ?? 0
            if height <= f.boundingRectForFont.height * CGFloat(lines) * 1.05 && widest <= width { return f }
            s *= 0.92
        }
        return font(name, size: s, bold: bold)
    }

    private static func text(_ string: String, font: NSFont, colour: MotionColor, in rect: CGRect, _ context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 0.92
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: colour.cg) ?? .white, .paragraphStyle: style])
            .draw(with: rect.insetBy(dx: 0, dy: -font.pointSize * 0.1), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Saving

    enum Format: String, CaseIterable, Identifiable {
        case png, jpeg
        var id: String { rawValue }
        var type: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    static func write(_ image: CGImage, to url: URL, format: Format) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The same design on other videos: each one's best frame, its name as the title when the design has none.
    static func batch(_ videos: [URL], design: Design, brand: Brand, sizes: [Size], format: Format, to folder: URL, ffmpeg: String,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [URL] {
        var written: [URL] = []
        for (n, video) in videos.enumerated() {
            guard let best = try? await candidates(video, ffmpeg: ffmpeg, count: 1) { p in progress((Double(n) + p) / Double(videos.count)) }.first,
                  let frame = await frame(video, at: best.time) else { continue }
            var mine = design
            if mine.title.trimmingCharacters(in: .whitespaces).isEmpty { mine.title = video.deletingPathExtension().lastPathComponent }
            for size in sizes {
                guard let rendered = render(frame, focus: best.focus, design: mine, brand: brand, size: size) else { continue }
                let url = folder.appendingPathComponent(fileName(video, size, format))
                if (try? write(rendered.image, to: url, format: format)) != nil { written.append(url) }
            }
        }
        return written
    }

    static func fileName(_ video: URL, _ size: Size, _ format: Format) -> String {
        "\(video.deletingPathExtension().lastPathComponent) \(Int(size.pixels.width))x\(Int(size.pixels.height)).\(format.fileExtension)"
    }
}
