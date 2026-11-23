import AVFoundation
import AppKit
import Vision

/// Social Cutdowns: a finished 16:9 edit as 9:16, 1:1 and 4:5 versions. Each shot gets its own
/// camera path that follows the subject (eased, holding still when the subject is), text and
/// logos are kept inside the format's safe area or flagged, and shots that can't be cropped well
/// are shown whole over a blurred fill or bars. Rendered with ffmpeg, sound copied as it is.
enum SocialCutdowns {
    typealias Format = Deliverables.Format
    static let formats: [Format] = [.vertical, .square, .portrait]
    /// Seconds between the looks at the picture.
    static let step = 0.2

    enum Framing: String, CaseIterable, Identifiable, Sendable, Codable {
        /// Cropped, following the subject.
        case follow
        /// The whole picture over a blurred copy of itself.
        case blur
        /// The whole picture between black bars.
        case bars
        var id: String { rawValue }
        var label: String {
            switch self {
            case .follow: String(localized: "Follow")
            case .blur: String(localized: "Blur fill")
            case .bars: String(localized: "Bars")
            }
        }
    }

    /// What Vision saw at one moment. Rectangles are normalised, top left origin.
    struct Sample: Sendable, Codable {
        var time: Double
        var faces: [CGRect] = []
        var people: [CGRect] = []
        var objects: [CGRect] = []
        var text: [CGRect] = []
        var thumb: [Float] = []
        /// The subject followed here (chosen so it doesn't flip between two people).
        var subject: CGRect?

        var candidates: [CGRect] { !faces.isEmpty ? faces : !people.isEmpty ? people : objects }
        // The thumbnail only finds cuts while analysing: not saved.
        enum CodingKeys: String, CodingKey { case time, faces, people, objects, text, subject }
    }

    struct Shot: Sendable, Identifiable, Equatable, Codable {
        var start: Double
        var end: Double
        /// Text and graphics on screen through most of the shot.
        var graphics: [CGRect] = []
        var id: Double { start }
    }

    struct Analysis: Sendable, Codable {
        var file: URL
        var width: Int
        var height: Int
        var fps: Double
        var duration: Double
        var samples: [Sample]
        var shots: [Shot]
        /// The brand profile's logo where it sits in the source (normalised), if it was found.
        var logo: CGRect?

        func samples(in shot: Shot) -> [Sample] { samples.filter { $0.time >= shot.start && $0.time < shot.end } }
        func shot(at time: Double) -> Shot? { shots.last { $0.start <= time + 0.0001 } }
    }

    /// What was changed by hand on one shot.
    struct ShotEdit: Sendable, Equatable, Codable {
        /// A subject picked and tracked: its centre (0…1 across) at each of the shot's samples.
        var path: [Double]?
        /// A crop dragged into place, per format: held there for the whole shot.
        var locks: [Format: Double] = [:]
        var framing: [Format: Framing] = [:]
    }

    /// How one shot comes out in one format.
    struct ShotPlan: Sendable {
        var start: Double
        var end: Double
        var framing: Framing
        /// The crop's centre (0…1 across the source) over time.
        var times: [Double]
        var centres: [Double]
        /// Text or a logo is cut off or sits outside the safe area.
        var flagged: Bool
        var locked: Bool

        func centre(at t: Double) -> Double {
            guard let first = times.first, let last = times.last else { return 0.5 }
            if t <= first { return centres[0] }
            if t >= last { return centres[centres.count - 1] }
            let i = times.firstIndex { $0 >= t } ?? times.count - 1
            let k = (t - times[i - 1]) / max(times[i] - times[i - 1], 1e-6)
            return centres[i - 1] + (centres[i] - centres[i - 1]) * k
        }
    }

    /// The crop's width as a share of the source's (full height kept).
    static func cropFraction(width: Int, height: Int, format: Format) -> Double {
        min(Double(height) * format.aspect / Double(max(width, 1)), 1)
    }

    /// Where text should stay inside the output (normalised, top left origin): clear of the apps'
    /// buttons and captions for vertical video.
    static func safeArea(_ format: Format) -> CGRect {
        let r = format == .vertical ? DeliveryCheck.Destination.social.safeArea : DeliveryCheck.Spec(id: "", name: "").safeArea
        return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Generic platform zones (buttons, captions, the top bar) on a vertical frame, normalised,
    /// top left origin. Drawn as plain overlays.
    enum Platform: String, CaseIterable, Identifiable, Sendable {
        case none, tiktok, reels, shorts
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: String(localized: "No overlay")
            case .tiktok: "TikTok"
            case .reels: "Reels"
            case .shorts: "Shorts"
            }
        }
        var zones: [CGRect] {
            switch self {
            case .none: []
            case .tiktok: [CGRect(x: 0, y: 0, width: 1, height: 0.09), CGRect(x: 0.86, y: 0.38, width: 0.14, height: 0.47),
                           CGRect(x: 0, y: 0.80, width: 1, height: 0.20)]
            case .reels: [CGRect(x: 0, y: 0, width: 1, height: 0.07), CGRect(x: 0.87, y: 0.50, width: 0.13, height: 0.38),
                          CGRect(x: 0, y: 0.83, width: 1, height: 0.17)]
            case .shorts: [CGRect(x: 0, y: 0, width: 1, height: 0.08), CGRect(x: 0.85, y: 0.45, width: 0.15, height: 0.42),
                           CGRect(x: 0, y: 0.84, width: 1, height: 0.16)]
            }
        }
    }

    // MARK: - Looking at the picture

    static func analyse(_ file: URL, ffmpeg: String?, brand: BrandProfile?,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> Analysis {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Converting.Failure.noVideo }
        let (natural, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = natural.applying(transform)
        let width = Int(abs(shown.width).rounded()), height = Int(abs(shown.height).rounded())
        let duration = try await asset.load(.duration).seconds
        guard duration > 0, width > 0 else { throw Converting.Failure.noVideo }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 4, preferredTimescale: 600)
        var times: [Double] = []
        var t = step / 2
        while t < duration { times.append(t); t += step }
        var samples: [Sample] = []
        for time in times {
            try Task.checkCancellation()
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            samples.append(look(at: image, time: time))
            progress(time / duration * 0.9)
        }

        // Cuts: ffmpeg's scene detection, plus big changes between neighbouring looks.
        var bounds: [Double] = []
        if let ffmpeg { bounds = await Shorts.cuts(in: file, from: 0, to: duration, ffmpeg: ffmpeg) }
        bounds = bounds.filter { $0 > 0.1 && $0 < duration - 0.1 }
        for i in samples.indices.dropFirst() where difference(samples[i - 1].thumb, samples[i].thumb) > 0.18 {
            let a = samples[i - 1].time, b = samples[i].time
            if !bounds.contains(where: { $0 > a - 0.05 && $0 < b + 0.05 }) { bounds.append((a + b) / 2) }
        }
        bounds = [0] + bounds.sorted() + [duration]
        var shots: [Shot] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1] - bounds[i] > 0.02 {
            shots.append(Shot(start: bounds[i], end: bounds[i + 1]))
        }

        // Per shot: the subject followed, and the graphics that stay.
        for s in shots.indices {
            let indices = samples.indices.filter { samples[$0].time >= shots[s].start && samples[$0].time < shots[s].end }
            var previous: CGRect?
            for i in indices {
                let candidates = samples[i].candidates
                let pick = previous.flatMap { p in candidates.min { distance($0, p) < distance($1, p) } }
                    ?? candidates.max { $0.width * $0.height < $1.width * $1.height }
                samples[i].subject = pick
                if let pick { previous = pick }
            }
            shots[s].graphics = steadyGraphics(indices.map { samples[$0].text })
        }

        let logo = await findLogo(brand, in: file, duration: duration)
        progress(1)
        return Analysis(file: file, width: width, height: height, fps: Double(rate > 0 ? rate : 25), duration: duration,
                        samples: samples, shots: shots, logo: logo)
    }

    /// The brand's logo in the edit (normalised, top left), looked for at a few moments.
    static func findLogo(_ brand: BrandProfile?, in file: URL, duration: Double) async -> CGRect? {
        guard let brand, let first = brand.logos.first, let picture = BrandProfile.image(of: first) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        for time in [duration * 0.1, duration * 0.5, duration * 0.9] {
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let frame = BrandLogoLocator.Frame(image), let match = BrandLogoLocator.find(picture, in: frame) else { continue }
            let w = Double(image.width), h = Double(image.height)
            return CGRect(x: match.rect.minX / w, y: match.rect.minY / h, width: match.rect.width / w, height: match.rect.height / h)
        }
        return nil
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        hypot(Double(a.midX - b.midX), Double(a.midY - b.midY))
    }

    private static func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    static func look(at image: CGImage, time: Double) -> Sample {
        let handler = VNImageRequestHandler(cgImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let plates = VNDetectRectanglesRequest()
        plates.maximumObservations = 8
        plates.minimumSize = 0.05
        try? handler.perform([faces, people, objects, text, plates])

        let plateRects = (plates.results ?? []).map { flipped($0.boundingBox) }
        // Text, grown to the plate behind it (a lower third's box), if there is one.
        let words: [CGRect] = (text.results ?? []).filter { $0.confidence > 0.3 && $0.boundingBox.height > 0.025 }.map { observation in
            let box = flipped(observation.boundingBox)
            return plateRects.filter { $0.contains(box) && $0.width * $0.height < box.width * box.height * 4 }
                .min { $0.width * $0.height < $1.width * $1.height } ?? box
        }
        // Salient things that aren't the text.
        let things = ((objects.results?.first)?.salientObjects ?? []).map { flipped($0.boundingBox) }.filter { thing in
            let covered = words.reduce(0.0) { $0 + Double($1.intersection(thing).width * $1.intersection(thing).height) }
            return covered < Double(thing.width * thing.height) * 0.5
        }
        return Sample(time: time,
                      faces: (faces.results ?? []).map { flipped($0.boundingBox) }.filter { $0.width * $0.height > 0.002 },
                      people: (people.results ?? []).filter { $0.confidence > 0.5 }.map { flipped($0.boundingBox) }.filter { $0.width * $0.height > 0.02 },
                      objects: things.sorted { $0.width * $0.height > $1.width * $1.height },
                      text: words, thumb: thumbnail(image))
    }

    /// Text that stays in one place for a good part of the shot (titles, lower thirds, a logo
    /// line), merged; text moving with the picture (a shirt, a sign going by) isn't a graphic.
    static func steadyGraphics(_ looks: [[CGRect]]) -> [CGRect] {
        func overlap(_ a: CGRect, _ b: CGRect) -> Double {
            let i = a.intersection(b)
            return i.isNull ? 0 : Double(i.width * i.height) / Double(min(a.width * a.height, b.width * b.height))
        }
        var clusters: [(first: CGRect, rect: CGRect, count: Int)] = []
        for look in looks {
            for box in look {
                if let i = clusters.firstIndex(where: { overlap($0.first, box) > 0.6 }) {
                    clusters[i].rect = clusters[i].rect.union(box)
                    clusters[i].count += 1
                } else {
                    clusters.append((box, box, 1))
                }
            }
        }
        let needed = max(min(2, looks.count), Int((Double(looks.count) * 0.25).rounded(.up)))
        return clusters.filter { $0.count >= needed }.map(\.rect)
    }

    private static func thumbnail(_ image: CGImage) -> [Float] {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels.map { Float($0) / 255 } : []
    }

    private static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count)
    }

    /// Follows the thing at `point` (normalised, top left) through its shot with Vision's object
    /// tracker, forwards and backwards from `time`: its centre at each of the shot's samples.
    static func track(_ analysis: Analysis, shot: Shot, time: Double, point: CGPoint) async -> [Double]? {
        let samples = analysis.samples(in: shot)
        guard let seedIndex = samples.indices.min(by: { abs(samples[$0].time - time) < abs(samples[$1].time - time) }) else { return nil }
        let seed = samples[seedIndex]
        let all = seed.faces + seed.people + seed.objects
        let start = all.filter { $0.contains(point) }.min { $0.width * $0.height < $1.width * $1.height }
            ?? CGRect(x: point.x - 0.06, y: point.y - 0.1, width: 0.12, height: 0.2)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: analysis.file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 4, preferredTimescale: 600)
        var centres = [Double?](repeating: nil, count: samples.count)
        centres[seedIndex] = Double(start.midX)
        for order in [Array(seedIndex..<samples.count), Array((0...seedIndex).reversed())] {
            var observation = VNDetectedObjectObservation(boundingBox: flipped(start))
            let sequence = VNSequenceRequestHandler()
            for i in order.dropFirst() {
                guard let image = try? await generator.image(at: CMTime(seconds: samples[i].time, preferredTimescale: 600)).image else { continue }
                let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                request.trackingLevel = .accurate
                guard (try? sequence.perform([request], on: image)) != nil,
                      let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.2 else { break }
                observation = result
                centres[i] = Double(result.boundingBox.midX)
            }
        }
        return filled(centres)
    }

    /// Gaps carried over from the nearest known value.
    static func filled(_ values: [Double?]) -> [Double] {
        guard let firstKnown = values.first(where: { $0 != nil }) ?? nil else { return values.map { _ in 0.5 } }
        var out: [Double] = []
        var last = firstKnown
        for value in values { if let value { last = value }; out.append(last) }
        return out
    }

    // MARK: - The camera path

    /// A steady path along the subject's centres (one per sample): outliers dropped, still while the
    /// subject is (or barely moves), otherwise a dead zone so small moves don't move the camera,
    /// then eased. Kept inside the source.
    static func smooth(_ raw: [Double], crop f: Double) -> [Double] {
        let low = f / 2, high = 1 - f / 2
        let clamp = { (x: Double) in min(max(x, low), high) }
        guard f < 0.999 else { return raw.map { _ in 0.5 } }
        guard raw.count > 2 else { return raw.map(clamp) }
        let median = raw.indices.map { i -> Double in
            let window = raw[max(0, i - 2)...min(raw.count - 1, i + 2)].sorted()
            return window[window.count / 2]
        }
        if (median.max()! - median.min()!) < f * 0.12 {
            let held = median.sorted()[median.count / 2]
            return raw.map { _ in clamp(held) }
        }
        let zone = f * 0.06
        var camera = median[0]
        let followed = median.map { x -> Double in
            if x - camera > zone { camera = x - zone } else if camera - x > zone { camera = x + zone }
            return camera
        }
        let sigma = 0.5 / step, radius = Int(sigma * 3)
        let weights = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return followed.indices.map { i in
            var sum = 0.0, total = 0.0
            for (k, w) in zip(-radius...radius, weights) {
                sum += followed[min(max(i + k, 0), followed.count - 1)] * w
                total += w
            }
            return clamp(sum / total)
        }
    }

    /// Every shot as it comes out in `format`.
    static func plan(_ analysis: Analysis, format: Format, edits: [Double: ShotEdit], ignoreLogo: Bool = false) -> [ShotPlan] {
        let f = cropFraction(width: analysis.width, height: analysis.height, format: format)
        let safe = safeArea(format)
        let low = f / 2, high = 1 - f / 2
        return analysis.shots.map { shot in
            let edit = edits[shot.start] ?? ShotEdit()
            let samples = analysis.samples(in: shot)
            var times = samples.map(\.time)
            var raw = filled(samples.map { $0.subject.map { Double($0.midX) } })
            if let path = edit.path, path.count == raw.count { raw = path }
            if times.isEmpty { times = [(shot.start + shot.end) / 2]; raw = [0.5] }
            var centres = smooth(raw, crop: f)

            // Graphics: inside the safe area of the crop, if the camera can keep the subject too.
            var graphics = shot.graphics
            if let logo = analysis.logo, !ignoreLogo { graphics.append(logo) }
            var flagged = false, wholeTitle = false
            var range = low...high
            for g in graphics {
                if g.minY < safe.minY || g.maxY > safe.maxY { flagged = true }
                let least = Double(g.maxX) + f / 2 - f * Double(safe.maxX)
                let most = Double(g.minX) + f / 2 - f * Double(safe.minX)
                let lower = max(range.lowerBound, least), upper = min(range.upperBound, most)
                if f >= 0.999 { continue }
                if lower > upper {
                    flagged = true
                    // A title wider than the crop: the whole picture shows it best.
                    if Double(g.width) > f * 0.96, g.height > 0.05 { wholeTitle = true }
                } else {
                    range = lower...upper
                }
            }
            if range != low...high {
                let kept = centres.map { min(max($0, range.lowerBound), range.upperBound) }
                if zip(kept, raw).allSatisfy({ abs($0 - $1) <= f * 0.4 }) { centres = kept } else { flagged = true }
            }
            var locked = false
            if let lock = edit.locks[format] {
                centres = centres.map { _ in min(max(lock, low), high) }
                locked = true
            }
            // A source narrower than the format has nothing to crop (following would stretch it): fit it on a blur.
            let narrower = f >= 0.999 && abs(Double(analysis.width) / Double(max(analysis.height, 1)) - format.aspect) > 0.01
            let framing = edit.framing[format] ?? (wholeTitle || narrower ? .blur : .follow)
            return ShotPlan(start: shot.start, end: shot.end, framing: framing, times: times, centres: centres,
                            flagged: flagged && framing == .follow, locked: locked)
        }
    }

    static func centre(_ plans: [ShotPlan], at t: Double) -> ShotPlan? { plans.last { $0.start <= t + 0.0001 } ?? plans.first }

    // MARK: - Brand

    /// A caption design in the brand's first font (when the Mac has it) and first colour.
    static func branded(_ design: CaptionDesign, _ brand: BrandProfile?) -> CaptionDesign {
        guard let brand else { return design }
        var design = design
        if let font = brand.fonts.first(where: { !CaptionFonts.faces(of: $0).isEmpty }) { design.font = font }
        if let hex = brand.palette.compactMap(\.hex).first, BrandProfile.rgb(hex: hex) != nil {
            design.color = hex.replacingOccurrences(of: "#", with: "").uppercased()
        }
        return design
    }

    /// Where the brand puts its logo in this format (output pixels, top left), and the picture.
    static func logoPlacement(_ brand: BrandProfile, format: Format) -> (image: CGImage, rect: CGRect)? {
        let size = CGSize(width: format.size.width, height: format.size.height)
        guard let placement = brand.placement(for: size), let logo = brand.logo(for: placement),
              let image = BrandProfile.image(of: logo) else { return nil }
        return (image, placement.rect(in: size, logoAspect: Double(image.width) / Double(max(image.height, 1))))
    }

    // MARK: - Rendering

    struct Render: Sendable {
        var format: Format
        var plans: [ShotPlan]
        var cues: [Transcript.Cue]?
        var design: CaptionDesign
        /// The brand logo drawn at the format's placement (the source's own logo hidden).
        var logo: (image: CGImage, rect: CGRect)?
        var folder: URL
        /// ProRes 422 HQ in a .mov, to finish in Resolve; else H.264.
        var proRes = false
    }

    /// The ffmpeg filter graph for one format (input 0 the source, 1 the logo if any; output [out]).
    static func filterGraph(_ analysis: Analysis, _ render: Render, commandFile: URL, captions: URL?) throws -> String {
        let (tw, th) = render.format.size
        let W = Double(analysis.width), H = analysis.height
        let f = cropFraction(width: analysis.width, height: analysis.height, format: render.format)
        let cropWidth = Int((W * f).rounded(.down)) / 2 * 2
        let frames = Int((analysis.duration * analysis.fps).rounded(.up))
        let x = { (t: Double) -> Int in
            let centre = (centre(render.plans, at: t)?.centre(at: t)) ?? 0.5
            return Int(min(max((centre - f / 2) * W, 0), W - Double(cropWidth)).rounded())
        }
        // One command a frame: the path is smooth to the frame.
        var lines: [String] = []
        var last = Int.min
        for n in 0..<max(frames, 1) {
            let t = Double(n) / analysis.fps
            let value = x(t)
            if value != last { lines.append(String(format: "%.4f crop@frame x %d;", max(t - 0.25 / analysis.fps, 0), value)); last = value }
        }
        try lines.joined(separator: "\n").write(to: commandFile, atomically: true, encoding: .utf8)

        func enable(_ framing: Framing) -> String? {
            let spans = render.plans.filter { $0.framing == framing }
            guard !spans.isEmpty else { return nil }
            return spans.map { String(format: "between(t\\,%.3f\\,%.3f)", $0.start, $0.end - 0.001) }.joined(separator: "+")
        }
        let blur = enable(.blur), bars = enable(.bars)
        var labels = ["[c]"]
        if blur != nil { labels += ["[b1]", "[b2]"] }
        if bars != nil { labels.append("[k]") }
        var graph: [String] = []
        var head = "[0:v]"
        if let source = analysis.logo, render.logo != nil {
            let r = CGRect(x: source.minX * W, y: source.minY * Double(H), width: source.width * W, height: source.height * Double(H))
                .insetBy(dx: -3, dy: -3).intersection(CGRect(x: 1, y: 1, width: W - 2, height: Double(H) - 2))
            head += "delogo=x=\(Int(r.minX)):y=\(Int(r.minY)):w=\(Int(r.width)):h=\(Int(r.height)),"
        }
        graph.append(head + (labels.count == 1 ? "null[c]" : "split=\(labels.count)" + labels.joined()))
        graph.append("[c]sendcmd=f=\(FFmpegFilter.path(commandFile)),crop@frame=w=\(cropWidth):h=\(H):x=\(x(0)):y=0,scale=\(tw):\(th):flags=lanczos,setsar=1[v0]")
        var current = "[v0]"
        let fitted = "scale=\(tw):\(th):force_original_aspect_ratio=decrease:flags=lanczos"
        if let blur {
            graph.append("[b1]scale=\(tw):\(th):force_original_aspect_ratio=increase,crop=\(tw):\(th),gblur=sigma=36,eq=brightness=-0.12:saturation=1.1[bg]")
            graph.append("[b2]\(fitted)[fg]")
            graph.append("[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1[blurred]")
            graph.append("\(current)[blurred]overlay=enable='\(blur)'[v1]")
            current = "[v1]"
        }
        if let bars {
            graph.append("[k]\(fitted),pad=\(tw):\(th):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[barred]")
            graph.append("\(current)[barred]overlay=enable='\(bars)'[v2]")
            current = "[v2]"
        }
        if let logo = render.logo {
            graph.append("[1:v]scale=\(Int(logo.rect.width.rounded())):-1[logo]")
            graph.append("\(current)[logo]overlay=\(Int(logo.rect.minX.rounded())):\(Int(logo.rect.minY.rounded()))[v3]")
            current = "[v3]"
        }
        if let captions {
            graph.append("\(current)\(Captions.filter(captions))[v4]")
            current = "[v4]"
        }
        graph.append("\(current)null[out]")
        return graph.joined(separator: ";")
    }

    /// The picture's encoder: ProRes 422 HQ (10 bit) or H.264 for posting straight away.
    static func videoArguments(proRes: Bool) -> [String] {
        proRes ? ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", "-vendor", "apl0"]
            : ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
    }

    /// Writes one format next to the others in `render.folder`: "<name>_9x16.mp4" (".mov" when the
    /// source isn’t an MP4 or for ProRes, so its sound can be copied as it is).
    static func render(_ analysis: Analysis, _ render: Render, ffmpeg: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-cutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var captions: URL?
        if let cues = render.cues, !cues.isEmpty {
            let url = work.appendingPathComponent("captions.ass")
            try Captions.subtitles(cues, width: render.format.size.width, height: render.format.size.height, design: render.design,
                                   bottom: render.format.subtitleMargin).write(to: url, atomically: true, encoding: .utf8)
            captions = url
        }
        var inputs = ["-i", analysis.file.path]
        if let logo = render.logo {
            let url = work.appendingPathComponent("logo.png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw Converting.Failure.unreadable }
            CGImageDestinationAddImage(destination, logo.image, nil)
            CGImageDestinationFinalize(destination)
            inputs += ["-i", url.path]
        }
        let graph = try filterGraph(analysis, render, commandFile: work.appendingPathComponent("path.txt"), captions: captions)
        let ext = !render.proRes && ["mp4", "m4v"].contains(analysis.file.pathExtension.lowercased()) ? "mp4" : "mov"
        let name = analysis.file.deletingPathExtension().lastPathComponent + "_" + render.format.tag
        let output = EditorExport.reserve(folder: render.folder.path, name: name, fileExtension: ext)
        let args = ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1"] + inputs
            + ["-filter_complex", graph, "-map", "[out]", "-map", "0:a?",
               ] + videoArguments(proRes: render.proRes) + ["-c:a", "copy", EditorExport.partial(output).path]
        let outcome = await EditorExport.run(ffmpeg, args, total: analysis.duration, progress: progress)
        switch outcome {
        case .done:
            guard EditorExport.finish(output) else { throw Converting.Failure.unreadable }
            return output
        case .stopped:
            try? FileManager.default.removeItem(at: EditorExport.partial(output))
            throw CancellationError()
        case .failed:
            try? FileManager.default.removeItem(at: EditorExport.partial(output))
            throw AIStudio.ToolFailure(message: EditorExport.readable(outcome) ?? String(localized: "The video couldn’t be written."))
        }
    }
}

/// The renders waiting and under way, one at a time.
@MainActor @Observable
final class CutdownQueue {
    static let shared = CutdownQueue()

    struct Job: Identifiable {
        enum State { case waiting, running(Double), done(URL), failed(String) }
        let id = UUID()
        var name: String
        var state = State.waiting
        let work: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL
    }

    private(set) var jobs: [Job] = []
    private var runner: Task<Void, Never>?
    private var runnerID = UUID()

    var busy: Bool { jobs.contains { if case .waiting = $0.state { true } else if case .running = $0.state { true } else { false } } }

    func add(_ name: String, work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL) {
        jobs.append(Job(name: name, work: work))
        guard runner == nil else { return }
        let token = UUID()
        runnerID = token
        runner = Task {
            while !Task.isCancelled, let index = jobs.firstIndex(where: { if case .waiting = $0.state { true } else { false } }) {
                let id = jobs[index].id
                jobs[index].state = .running(0)
                do {
                    let url = try await jobs[index].work { share in
                        Task { @MainActor in self.update(id, .running(share)) }
                    }
                    update(id, .done(url))
                } catch is CancellationError {
                    update(id, .failed(String(localized: "Stopped")))
                } catch {
                    update(id, .failed(error.localizedDescription))
                }
            }
            // A stopped run must not clear a newer one.
            if runnerID == token { runner = nil }
        }
    }

    private func update(_ id: UUID, _ state: Job.State) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A late progress report never undoes the end.
        if case .running = state, case .done = jobs[i].state { return }
        if case .running = state, case .failed = jobs[i].state { return }
        jobs[i].state = state
    }

    func stop() {
        runner?.cancel()
        runner = nil
        jobs.removeAll { if case .waiting = $0.state { true } else { false } }
    }

    func clearFinished() {
        jobs.removeAll { if case .done = $0.state { true } else if case .failed = $0.state { true } else { false } }
    }
}
