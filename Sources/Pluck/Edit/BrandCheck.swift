import AVFoundation
import ImageIO
import Vision

/// Delivery Check against a brand profile: the logo found in full-size frames and measured
/// against its rule (position to a tenth of a pixel, width, colour, clear space, when it shows),
/// and the texts that must or mustn't be on screen. Every Nth frame is looked at, and every frame
/// of the end card. Runs on this Mac.
enum BrandCheck {
    /// Frames between looks outside the end card.
    static var sampleEvery = 12

    // MARK: - Frames

    struct Video {
        let generator: AVAssetImageGenerator
        let fps: Double
        let duration: Double

        init?(_ file: URL, duration: Double? = nil) async {
            let asset = AVURLAsset(url: file)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
            let rate = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            fps = rate > 1 ? rate : 25
            if let duration { self.duration = duration } else { self.duration = (try? await asset.load(.duration).seconds) ?? 0 }
            generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }

        var frameCount: Int { max(Int((duration * fps).rounded(.down)), 1) }

        /// Frame `n` exactly (asked for mid-frame, so rounding can't land on its neighbour).
        func frame(_ n: Int) async -> CGImage? {
            try? await generator.image(at: CMTime(seconds: (Double(n) + 0.5) / fps, preferredTimescale: 60000)).image
        }
    }

    /// A still (PNG, JPEG, TIFF…), else nil.
    static func still(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) as String?, !type.contains("gif") else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Text on screen

    struct Words {
        var text: String
        /// Normalised, origin bottom left.
        var box: CGRect
    }

    static func words(in image: CGImage) -> [Words] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // As written: correcting it would hide typos and change legal lines.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.4 else { return nil }
            return Words(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// Lower case, letters and digits only, single spaces: how texts are compared.
    static func normalised(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Running

    private struct Event {
        var kind: String
        var index: Int
        var time: Double
        var severity: DeliveryCheck.Issue.Severity
        var title: String
        var detail: String
        /// The worst sample's detail is the one kept.
        var weight: Double
        var box: CGRect?
    }

    static func run(file: URL, profile: BrandProfile, duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async -> [DeliveryCheck.Issue] {
        guard let video = await Video(file, duration: duration), video.duration > 0, let first = await video.frame(0) else { return [] }
        let size = CGSize(width: first.width, height: first.height)
        var issues: [DeliveryCheck.Issue] = []
        var events: [Event] = []

        // The logo's rule for this size.
        var rule: (placement: BrandProfile.Placement, logo: CGImage, expected: CGRect, k: Double)?
        if !profile.logos.isEmpty {
            if let placement = profile.placement(for: size), let logo = profile.logo(for: placement) {
                let k = size.width / Double(max(placement.referenceWidth, 1))
                if let picture = BrandProfile.image(of: logo, width: max(1200, placement.width * k * 2)) {
                    let expected = placement.rect(in: size, logoAspect: Double(picture.width) / Double(picture.height))
                    rule = (placement, picture, expected, k)
                }
            } else {
                issues.append(.init(severity: .note, title: String(localized: "No logo rule for this size"),
                                    detail: String(localized: "The brand profile has no logo placement for \(String(Int(size.width)))×\(String(Int(size.height))).")))
            }
        }

        let texts = !profile.requiredTexts.isEmpty || !profile.forbiddenTexts.isEmpty || profile.clearSpace.amount > 0
        let palette = profile.checkPalette ? profile.palette.compactMap { $0.hex.flatMap(BrandProfile.rgb(hex:)) } : []
        let last = video.frameCount - 1
        let endStart = profile.timing.mode == .endCard ? max(Int(((video.duration - profile.timing.endCard) * video.fps).rounded(.up)), 0) : last
        let frames = (0...last).filter { $0 % sampleEvery == 0 || $0 >= endStart || $0 == last }
        let inEndCard = { (n: Int) in n >= endStart && profile.timing.mode == .endCard }
        var read: [(index: Int, time: Double, endCard: Bool, words: [Words])] = []
        var paletteSeen: [SIMD3<Double>] = []

        for (index, n) in frames.enumerated() {
            if Task.isCancelled { return [] }
            progress(Double(index) / Double(frames.count))
            guard let image = n == 0 ? first : await video.frame(n), let frame = BrandLogoLocator.Frame(image) else { continue }
            let time = Double(n) / video.fps
            let reading = texts && (n % sampleEvery == 0 || n == last)
            let words = reading ? Self.words(in: image) : []
            if reading { read.append((read.count, time, inEndCard(n), words)) }

            if let rule {
                let match = BrandLogoLocator.locate(rule.logo, in: frame, expected: rule.expected)
                events += logoEvents(match, rule: rule, profile: profile, frame: frame, words: reading ? words : nil,
                                     index: index, time: time, duration: video.duration)
            }
            if !palette.isEmpty, n % sampleEvery == 0 || n == last, profile.timing.mode != .endCard || inEndCard(n) {
                for colour in offPalette(frame, palette: palette) where !paletteSeen.contains(where: { BrandProfile.deltaE($0, colour.rgb) < 6 }) {
                    paletteSeen.append(colour.rgb)
                    issues.append(.init(severity: .note, time: time, title: String(localized: "Colour outside the brand palette"),
                                        detail: String(localized: "\(BrandProfile.hex(colour.rgb)) covers \(Int((colour.share * 100).rounded())) % of the picture.")))
                }
            }
        }
        progress(1)
        events += textEvents(read, profile: profile)
        issues += grouped(events)
        issues.sort { ($0.severity, $0.time ?? -1) < ($1.severity, $1.time ?? -1) }
        return issues
    }

    private static func box(_ rect: CGRect, in frame: BrandLogoLocator.Frame) -> CGRect {
        let w = Double(frame.width), h = Double(frame.height)
        return CGRect(x: rect.minX / w, y: 1 - rect.maxY / h, width: rect.width / w, height: rect.height / h)
    }

    /// The corner (or centre) the rule measures from.
    private static func anchorPoint(_ rect: CGRect, _ anchor: BrandProfile.Anchor) -> CGPoint {
        switch anchor {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .centre: CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    /// "1", "1.5": pixels to a tenth, without a needless ".0".
    static func pixels(_ value: Double) -> String {
        let tenth = (value * 10).rounded() / 10
        return tenth == tenth.rounded() ? String(Int(tenth)) : String(format: "%.1f", tenth)
    }

    private static func logoEvents(_ match: BrandLogoLocator.Match?, rule: (placement: BrandProfile.Placement, logo: CGImage, expected: CGRect, k: Double),
                                   profile: BrandProfile, frame: BrandLogoLocator.Frame, words: [Words]?,
                                   index: Int, time: Double, duration: Double) -> [Event] {
        let placement = rule.placement, k = rule.k
        var events: [Event] = []
        func add(_ kind: String, _ severity: DeliveryCheck.Issue.Severity, _ title: String, _ detail: String, _ weight: Double, _ rect: CGRect) {
            events.append(Event(kind: kind, index: index, time: time, severity: severity, title: title, detail: detail, weight: weight,
                                box: box(rect, in: frame)))
        }
        guard let match else {
            if profile.timing.required(at: time, duration: duration) {
                let endCard = profile.timing.mode == .endCard
                add("missing", .problem, endCard ? String(localized: "Logo missing in end card") : String(localized: "Logo missing"),
                    String(localized: "The logo isn’t where the brand profile puts it."), 0, rule.expected)
            }
            return events
        }
        let rect = match.rect
        if profile.timing.forbidden(at: time) {
            add("early", .warning, String(localized: "Logo shown too early"),
                String(localized: "It mustn’t show in the first \(pixels(profile.timing.notInFirst)) s."), 0, rect)
        }

        // Position, at the corner the rule measures from, in the rule's pixels.
        let found = anchorPoint(rect, placement.anchor), wanted = anchorPoint(rule.expected, placement.anchor)
        let dx = (found.x - wanted.x) / k, dy = (found.y - wanted.y) / k
        let off = max(abs(dx), abs(dy))
        if (off * 10).rounded() / 10 > placement.tolerance {
            let across = dx >= 0 ? String(localized: "\(pixels(abs(dx))) px right") : String(localized: "\(pixels(abs(dx))) px left")
            let down = dy >= 0 ? String(localized: "\(pixels(abs(dy))) px down") : String(localized: "\(pixels(abs(dy))) px up")
            add("off", .problem, String(localized: "Logo off by \(pixels(off)) px"),
                String(localized: "\(across) and \(down) from its place (allowed: \(pixels(placement.tolerance)) px)."), off, rect)
        }

        // Size.
        let width = rect.width / k, error = (rect.width / rule.expected.width - 1) * 100
        if abs(error) > placement.scaleTolerance {
            add(error > 0 ? "large" : "small", .problem, error > 0 ? String(localized: "Logo too large") : String(localized: "Logo too small"),
                String(localized: "\(pixels(width)) px wide, not \(pixels(placement.width)) px (\(String(format: "%+.1f", error)) %)."), abs(error), rect)
        } else if profile.minimumWidth > 0, width < profile.minimumWidth {
            add("small", .problem, String(localized: "Logo too small"),
                String(localized: "\(pixels(width)) px wide; the smallest allowed is \(pixels(profile.minimumWidth)) px."), profile.minimumWidth - width, rect)
        }

        // Colour.
        let wantedColour = profile.logoColour.flatMap(BrandProfile.rgb(hex:)) ?? match.ownColour
        let difference = BrandProfile.deltaE(match.colour, wantedColour)
        if difference > profile.colourTolerance {
            add("colour", .problem, String(localized: "Wrong logo colour"),
                String(localized: "Shown as \(BrandProfile.hex(match.colour)), should be \(BrandProfile.hex(wantedColour)) (ΔE \(String(format: "%.1f", difference)))."),
                difference, rect)
        }

        // Clear space: text first (it says what), else any clear edges. One kind, so a run of
        // frames (read or not) is one issue; text makes it a warning, shapes alone a note.
        let space = profile.clearSpace.pixels(logoWidth: rect.width, scale: k)
        if space > 0 {
            let outer = rect.insetBy(dx: -space, dy: -space), inner = rect.insetBy(dx: -2, dy: -2)
            let intruder = (words ?? []).first { word in
                let b = word.box, w = Double(frame.width), h = Double(frame.height)
                let r = CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
                // (The logo's own letters read as text sit on the logo.)
                let onLogo = r.intersection(inner)
                return r.intersects(outer) && onLogo.width * onLogo.height < 0.5 * r.width * r.height
            }
            if let intruder {
                add("space", .warning, String(localized: "Something inside the logo’s clear space"),
                    String(localized: "“\(intruder.text)” is within \(pixels(space / k)) px of the logo."), 1, outer)
            } else if frame.edgeShare(outer: outer, inner: inner) > 0.01 {
                add("space", .note, String(localized: "Something inside the logo’s clear space"),
                    String(localized: "Lines or shapes within \(pixels(space / k)) px of the logo."), 0, outer)
            }
        }
        return events
    }

    private static func textEvents(_ read: [(index: Int, time: Double, endCard: Bool, words: [Words])], profile: BrandProfile) -> [Event] {
        func text(_ words: [Words], area: BrandProfile.RequiredText.Area) -> String {
            let kept = words.filter { area == .anywhere || (area == .top ? $0.box.midY > 0.5 : $0.box.midY <= 0.5) }
                .sorted { $0.box.midY != $1.box.midY ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
            return " " + normalised(kept.map(\.text).joined(separator: " ")) + " "
        }
        var events: [Event] = []
        for forbidden in profile.forbiddenTexts {
            let needle = " " + normalised(forbidden) + " "
            guard needle.count > 2 else { continue }
            for sample in read where text(sample.words, area: .anywhere).contains(needle) {
                events.append(Event(kind: "forbidden-" + needle, index: sample.index, time: sample.time, severity: .problem,
                                    title: String(localized: "Forbidden text"), detail: String(localized: "“\(forbidden)” is on screen."), weight: 0))
            }
        }
        for required in profile.requiredTexts {
            let needle = " " + normalised(required.text) + " "
            guard needle.count > 2, !read.isEmpty else { continue }
            let pool = required.when == .endCard ? read.filter(\.endCard) : read
            let missing = pool.filter { !text($0.words, area: required.area).contains(needle) }
            let title = String(localized: "Required text missing")
            switch required.when {
            case .always:
                for sample in missing {
                    events.append(Event(kind: "required-" + needle, index: sample.index, time: sample.time, severity: .problem,
                                        title: title, detail: String(localized: "“\(required.text)” isn’t on screen."), weight: 0))
                }
            case .anytime, .endCard:
                if missing.count == pool.count {
                    let detail = required.when == .endCard ? String(localized: "“\(required.text)” isn’t in the end card.")
                                                            : String(localized: "“\(required.text)” never shows.")
                    events.append(Event(kind: "required-" + needle, index: 0, time: pool.first?.time ?? 0, severity: .problem,
                                        title: title, detail: detail, weight: 0))
                }
            }
        }
        return events
    }

    /// Large flat, colourful areas whose colour isn't near any palette colour.
    private static func offPalette(_ frame: BrandLogoLocator.Frame, palette: [SIMD3<Double>]) -> [(rgb: SIMD3<Double>, share: Double)] {
        var bins: [Int: (count: Int, total: SIMD3<Double>)] = [:]
        var pixels = 0
        for y in Swift.stride(from: 0, to: frame.height, by: 2) {
            for x in Swift.stride(from: 0, to: frame.width, by: 2) {
                pixels += 1
                let c = frame.colour(x: x, y: y)
                guard c.max() - c.min() > 0.15 else { continue }
                let key = Int(c.x * 15.99) << 8 | Int(c.y * 15.99) << 4 | Int(c.z * 15.99)
                bins[key, default: (0, .zero)].count += 1
                bins[key, default: (0, .zero)].total += c
            }
        }
        return bins.values.filter { Double($0.count) / Double(max(pixels, 1)) > 0.03 }
            .map { ($0.total / Double($0.count), Double($0.count) / Double(max(pixels, 1))) }
            .filter { colour in palette.allSatisfy { BrandProfile.deltaE($0, colour.0) > 12 } }
    }

    /// Runs of the same finding in consecutive looks, as one issue over that time.
    private static func grouped(_ events: [Event]) -> [DeliveryCheck.Issue] {
        var issues: [DeliveryCheck.Issue] = []
        for kind in Set(events.map(\.kind)) {
            let run = events.filter { $0.kind == kind }.sorted { $0.index < $1.index }
            var start = 0
            for i in run.indices where i == run.count - 1 || run[i + 1].index != run[i].index + 1 {
                let part = run[start...i], worst = part.max { $0.weight < $1.weight }!
                issues.append(.init(severity: worst.severity, time: part.first!.time, end: part.count > 1 ? part.last!.time : nil,
                                    title: worst.title, detail: worst.detail, box: worst.box))
                start = i + 1
            }
        }
        return issues
    }

    // MARK: - Measuring an approved video

    struct Measurement {
        var placement: BrandProfile.Placement
        /// When the logo shows in the video (nil for a still).
        var timing: BrandProfile.Timing?
        /// The logo's colour as shown.
        var colour: String
    }

    /// The logo found in an approved video or still: its exact place and width (nearest corner as
    /// the anchor), when it shows, and its colour.
    static func measure(file: URL, logo: BrandProfile.Logo, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Measurement? {
        guard let picture = BrandProfile.image(of: logo, width: 1600) else { return nil }
        if let image = still(file), let frame = BrandLogoLocator.Frame(image) {
            guard let match = BrandLogoLocator.find(picture, in: frame) else { return nil }
            return Measurement(placement: placement(match.rect, in: CGSize(width: image.width, height: image.height), logo: logo),
                               timing: nil, colour: BrandProfile.hex(match.colour))
        }
        guard let video = await Video(file) else { return nil }
        let last = video.frameCount - 1
        // The end usually has it (an end card); else a few frames through the video.
        var match: BrandLogoLocator.Match?, size = CGSize.zero, foundAt = last
        for n in [last] + stride(from: 0, to: last, by: max(last / 8, 1)) {
            guard let image = await video.frame(n), let frame = BrandLogoLocator.Frame(image) else { continue }
            size = CGSize(width: image.width, height: image.height)
            if let found = BrandLogoLocator.find(picture, in: frame) { match = found; foundAt = n; break }
        }
        guard let match else { return nil }
        progress(0.3)
        func present(_ n: Int) async -> Bool {
            guard let image = await video.frame(n), let frame = BrandLogoLocator.Frame(image) else { return false }
            return BrandLogoLocator.locate(picture, in: frame, expected: match.rect) != nil
        }
        /// The last frame it's on, going from `from` by `step` (±1): coarse looks, then frame by frame.
        func edge(from: Int, step: Int) async -> Int {
            var on = from, n = from + step * sampleEvery
            while n >= 0, n <= last, await present(n) { on = n; n += step * sampleEvery }
            var m = on + step
            while m >= 0, m <= last, m != n, await present(m) { on = m; m += step }
            return on
        }
        let start = await edge(from: foundAt, step: -1)
        progress(0.6)
        let end = await edge(from: foundAt, step: 1)
        var timing = BrandProfile.Timing()
        if start > 0, end == last {
            timing.mode = .endCard
            timing.endCard = ((video.duration - Double(start) / video.fps) * 100).rounded() / 100
        } else if start > 0 || end < last {
            timing.mode = .ranges
            timing.ranges = [.init(start: (Double(start) / video.fps * 100).rounded() / 100, end: (Double(end + 1) / video.fps * 100).rounded() / 100)]
        }
        progress(1)
        return Measurement(placement: placement(match.rect, in: size, logo: logo), timing: timing, colour: BrandProfile.hex(match.colour))
    }

    /// A rule for a logo at `rect`, from its nearest corner (or the centre), to a tenth of a pixel.
    static func placement(_ rect: CGRect, in size: CGSize, logo: BrandProfile.Logo) -> BrandProfile.Placement {
        var placement = BrandProfile.Placement()
        placement.logoID = logo.id
        placement.referenceWidth = Int(size.width); placement.referenceHeight = Int(size.height)
        let centred = abs(rect.midX - size.width / 2) < size.width * 0.05 && abs(rect.midY - size.height / 2) < size.height * 0.05
        let left = rect.midX < size.width / 2, top = rect.midY < size.height / 2
        placement.anchor = centred ? .centre : top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        let offsets = placement.offsets(of: rect, in: size)
        func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        placement.x = tenth(offsets.x); placement.y = tenth(offsets.y); placement.width = tenth(rect.width)
        return placement
    }
}
