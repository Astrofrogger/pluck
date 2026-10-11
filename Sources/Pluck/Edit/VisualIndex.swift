import AVFoundation
import CoreImage
import Foundation
import FoundationModels
import NaturalLanguage
import Vision

/// Visual search for the Library: every video cut into shots, and each shot described (what's
/// in it, where, shot size), measured (camera movement) and made searchable in your own words.
/// Runs on this Mac: Apple's on-device model describes the pictures (macOS 27 with Apple
/// Intelligence); without it, Vision's labels stand in.
enum VisualIndex {
    enum Movement: String, Codable, CaseIterable, Sendable {
        case still, pan, tilt, zoomIn, zoomOut, whipPan, handheld, moving

        var label: String {
            switch self {
            case .still: String(localized: "Static")
            case .pan: String(localized: "Pan")
            case .tilt: String(localized: "Tilt")
            case .zoomIn: String(localized: "Push in")
            case .zoomOut: String(localized: "Pull out")
            case .whipPan: String(localized: "Whip pan")
            case .handheld: String(localized: "Handheld")
            case .moving: String(localized: "Moving shot")
            }
        }

        /// English words the search matches on.
        var words: String {
            switch self {
            case .still: "static locked off tripod still"
            case .pan: "pan panning"
            case .tilt: "tilt tilting"
            case .zoomIn: "push in zoom in dolly in"
            case .zoomOut: "pull out zoom out dolly out reveal"
            case .whipPan: "whip pan swish pan fast pan"
            case .handheld: "handheld shaky"
            case .moving: "moving camera tracking dolly gimbal"
            }
        }
    }

    enum Framing: String, Codable, CaseIterable, Sendable {
        case closeUp, medium, wide, aerial

        var label: String {
            switch self {
            case .closeUp: String(localized: "Close-up")
            case .medium: String(localized: "Medium")
            case .wide: String(localized: "Wide")
            case .aerial: String(localized: "Aerial")
            }
        }

        var words: String {
            switch self {
            case .closeUp: "close-up closeup close up"
            case .medium: "medium shot"
            case .wide: "wide shot establishing"
            case .aerial: "aerial drone birds-eye overhead"
            }
        }
    }

    struct Shot: Codable, Identifiable, Sendable, Hashable {
        var start: Double
        var end: Double
        var description: String
        var keywords: [String]
        var framing: Framing
        var movement: Movement
        var embedding: [Float]?
        /// How good and how interesting the shot is, for picking selects (nil in older indexes).
        var quality: Quality?
        /// A steady, even camera move (gimbal, slider, drone): one that can be speed-ramped.
        var smooth: Bool?
        var id: Double { start }
    }

    struct Quality: Codable, Sendable, Hashable {
        /// Edge detail of the sharpest of three looks (variance of the Laplacian).
        var sharpness: Double
        /// How in focus, 0…1, whatever is in the picture: how much detail a slight blur takes
        /// away (a sharp picture loses most of it, a soft one has little left to lose).
        var sharpnessShare: Double
        var brightness: Double
        /// Share of the picture blown out (near white) or crushed (near black).
        var blown: Double
        var crushed: Double
        /// Camera shake, and movement within the picture (people working, a hoist going up).
        var shake: Double
        var action: Double
        var faces: Int
        /// Vision's face capture quality of the best face (0…1): in focus, eyes open, facing us.
        var faceQuality: Double
        /// Smiling or happy people, and what's happening, as the local AI sees it.
        var smiling: Bool
        var activity: String
        /// The look, as a videographer would name it (silhouette, lens flare, shallow depth of
        /// field…; empty for a plain shot), and the feeling it gives.
        var look: String = ""
        var emotion: String = ""
        /// Apple Vision's aesthetics score (−1…1): how well composed and lit, as a photo.
        var aesthetics: Double = 0 
        /// How usable and interesting, 0…1.
        var score: Double
        var problems: [Problem]
    }

    enum Problem: String, Codable, Sendable, Hashable {
        case soft, dark, blown, shaky

        var label: String {
            switch self {
            case .soft: String(localized: "Soft")
            case .dark: String(localized: "Dark")
            case .blown: String(localized: "Overexposed")
            case .shaky: String(localized: "Shaky")
            }
        }
    }

    struct FileIndex: Codable, Sendable {
        var path: String
        var modified: Date
        /// How the pictures were described: "model" (on-device language model) or "labels".
        var describer: String
        var shots: [Shot]
    }

    struct Hit: Identifiable, Sendable, Hashable {
        var path: String
        var shot: Shot
        var score: Double
        var id: String { path + "@\(shot.start)" }
    }

    // MARK: - Storage

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/VisualIndex", isDirectory: true)
    }

    static var thumbnails: URL { folder.appendingPathComponent("Shots", isDirectory: true) }

    private static func key(_ path: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    static func indexURL(for path: String) -> URL { folder.appendingPathComponent(key(path) + ".json") }

    static func thumbnailURL(path: String, start: Double) -> URL {
        thumbnails.appendingPathComponent("\(key(path))-\(Int(start * 10)).jpg")
    }

    static func load(_ path: String) -> FileIndex? {
        guard let data = try? Data(contentsOf: indexURL(for: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FileIndex.self, from: data)
    }

    static func save(_ index: FileIndex) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(index).write(to: indexURL(for: index.path), options: .atomic)
    }

    /// Whether the file has an up-to-date index.
    static func isIndexed(_ file: URL) -> Bool {
        guard let index = load(file.path),
              let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
        return abs(index.modified.timeIntervalSince(modified)) < 1 && index.describer == describer
    }

    /// Who describes the pictures here: the open model (Qwen) when it's installed, else Apple's
    /// on-device model, else Vision's labels. An index made by a lesser one is redone.
    static var describer: String {
        if let model = VisionModel.ready { return model.repository }
        return canDescribe ? "model" : "labels"
    }

    /// Whether the on-device model can describe pictures here.
    static var canDescribe: Bool {
        guard #available(macOS 27, *) else { return false }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.capabilities.contains(.vision)
    }

    // MARK: - Indexing

    /// Cuts a video into shots and describes each one. `progress` gets 0…1.
    static func index(_ file: URL, ffmpeg: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> FileIndex {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.5 else { throw Failure.noVideo }
        // Shots: hard cuts, and long shots in pieces of about eight seconds so each part is found.
        let cuts = await Shorts.cuts(in: file, from: 0, to: duration, ffmpeg: ffmpeg)
        // Pieces under 0.8 s are usually fast camera moves read as cuts: they join the shot before.
        var kept: [Double] = [0]
        for cut in cuts.sorted() where cut > 0.4 && cut < duration - 0.4 {
            if cut - kept[kept.count - 1] >= 0.8 { kept.append(cut) }
        }
        var bounds = kept + [duration]
        // Within a shot, a camera move (a push-in, a pan…) is a shot of its own, start to end, so
        // two push-ins are two shots. The rest is cut in pieces of about eight seconds.
        var split: [Double] = [bounds[0]]
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            for part in await Self.moves(in: asset, from: a, to: b) {
                let pieces = part.isMove ? 1 : max(1, Int(((part.end - part.start) / 8).rounded()))
                for n in 1...pieces { split.append(part.start + (part.end - part.start) * Double(n) / Double(pieces)) }
            }
        }
        bounds = split

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)

        let describer = Self.describer
        let qwen = VisionModel.ready != nil
        let describe = qwen || canDescribe
        let frameFile = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-shot-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: frameFile) }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        var shots: [Shot] = []
        let total = bounds.count - 1
        for (number, (start, end)) in zip(bounds, bounds.dropFirst()).enumerated() {
            try Task.checkCancellation()
            progress(Double(number) / Double(max(total, 1)))
            guard end - start > 0.2 else { continue }
            let middle = (start + end) / 2
            guard let frame = try? await generator.image(at: CMTime(seconds: middle, preferredTimescale: 600)).image else { continue }
            let (framing, people) = Self.framing(of: frame)
            let motion = await Self.movement(generator: generator, from: start, to: end)
            let movement = motion.movement
            var description = "", keywords: [String] = []
            var seen = Seen()
            var found: Seen?
            if qwen {
                Self.saveThumbnail(frame, to: frameFile, width: 640)
                found = try? await Self.describeWithQwen(frameFile)
            }
            if found == nil, canDescribe, #available(macOS 27, *) { found = try? await Self.describe(frame) }
            if let found {
                seen = found
                description = found.description
                keywords = found.keywords
            }
            // Sharpness: the best of three looks (focus can be found or lost within a shot).
            var looks = [frame]
            for share in [0.25, 0.75] {
                if let image = try? await generator.image(at: CMTime(seconds: start + (end - start) * share, preferredTimescale: 600)).image {
                    looks.append(image)
                }
            }
            let measured = looks.map(Self.measure)
            let exposure = measured[0]
            let faces = Self.faces(in: frame)
            let aesthetics = Self.aesthetics(of: frame)
            if description.isEmpty {
                keywords = Self.labels(of: frame)
                description = keywords.prefix(4).joined(separator: ", ")
            }
            // A description that says "aerial" or "drone" is an aerial shot, whatever the faces say.
            var shotFraming = framing
            let lower = (description + " " + keywords.joined(separator: " ")).lowercased()
            if ["aerial", "drone", "bird's-eye", "birds-eye", "overhead view"].contains(where: lower.contains) { shotFraming = .aerial }
            else if people == 0, shotFraming == .medium, lower.contains("wide") { shotFraming = .wide }
            let text = [description, keywords.joined(separator: ", "), seen.activity, seen.look, seen.emotion,
                        shotFraming.words, movement.words].joined(separator: ". ")
            let vector = embedding?.vector(for: text).map { $0.map(Float.init) }
            // In focus: 0.85 and up is crisp, 0.6 and below is soft (see measure).
            let focus = measured.map(\.focus).max() ?? 0
            let quality = Quality(sharpness: measured.map(\.sharpness).max() ?? 0, sharpnessShare: min(1, max(0, (focus - 0.6) / 0.25)),
                                  brightness: exposure.brightness, blown: exposure.blown, crushed: exposure.crushed,
                                  shake: motion.shake, action: motion.action, faces: faces.count, faceQuality: faces.quality,
                                  smiling: seen.smiling, activity: seen.activity, look: seen.look, emotion: seen.emotion,
                                  aesthetics: aesthetics,
                                  score: 0, problems: [])
            shots.append(Shot(start: start, end: end, description: description, keywords: keywords,
                              framing: shotFraming, movement: movement, embedding: vector, quality: quality,
                              smooth: motion.smooth))
            Self.saveThumbnail(frame, to: thumbnailURL(path: file.path, start: start))
        }
        progress(1)
        Self.score(&shots)
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        let index = FileIndex(path: file.path, modified: modified, describer: describe ? describer : "labels", shots: shots)
        save(index)
        return index
    }

    enum Failure: LocalizedError {
        case noVideo
        var errorDescription: String? { String(localized: "Pluck couldn’t read the video.") }
    }

    struct Seen: Sendable {
        var description = "", keywords: [String] = [], smiling = false, activity = "", look = "", emotion = ""
    }

    /// The six-line question both models answer about a frame.
    private static let describeInstructions = """
            You catalogue video footage for a video editor, with a videographer's eye. Answer in exactly six lines, in English:
            1. One short line: the subject, the setting, the shot size (close-up, medium, wide or aerial) and \
            anything notable (light, weather).
            2. Up to 8 comma-separated search keywords.
            3. The mood of the people: smiling (visibly smiling or laughing), neutral, focused, or none.
            4. What is happening in a few words (for example "technician climbing a truss"), or none.
            5. The look, only if something clearly stands out as a videographer would name it (for example a \
            silhouette, lens flare, shallow depth of field, symmetry, golden light, motion blur); otherwise plain.
            6. The feeling the shot gives, in one or two words (for example pride, energy, calm, focus, scale, joy).
            """

    @available(macOS 27, *)
    private static func describe(_ image: CGImage) async throws -> Seen {
        let session = LanguageModelSession(instructions: describeInstructions)
        let response = try await session.respond {
            "Describe this frame."
            Attachment(image)
        }
        return parse(response.content)
    }

    /// The open model, in Pluck's helper: sharper descriptions, looks and feelings.
    private static func describeWithQwen(_ frame: URL) async throws -> Seen {
        let text = try await VisionRunner.shared.describe(frame, instructions: describeInstructions,
                                                          prompt: "Describe this frame. Answer with the six lines only.")
        let seen = parse(text)
        guard !seen.description.isEmpty else { throw VisionModel.Failure.helper("empty answer") }
        return seen
    }

    private static func parse(_ text: String) -> Seen {
        // By position: the model sometimes adds labels ("MOOD:") or numbers, sometimes not.
        let lines = text.split(whereSeparator: \.isNewline).map { raw -> String in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let dot = line.firstIndex(of: "."), !line[..<dot].isEmpty, line[..<dot].allSatisfy(\.isNumber) {
                line = line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            }
            if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) < 12,
               line[..<colon].allSatisfy({ $0.isLetter || $0 == " " }) {
                line = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return line
        }.filter { !$0.isEmpty }
        func line(_ n: Int) -> String { n < lines.count ? lines[n] : "" }
        func nothing(_ text: String) -> Bool { ["none", "plain", "n/a", ""].contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        var seen = Seen()
        seen.description = line(0)
        seen.keywords = Array(line(1).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() }
            .filter { !$0.isEmpty }.prefix(8))
        let mood = line(2).lowercased()
        seen.smiling = mood.contains("smil") || mood.contains("laugh") || mood.contains("happy") || mood.contains("joy")
        seen.activity = nothing(line(3)) ? "" : line(3)
        seen.look = Self.techniques(in: line(4))
        seen.emotion = nothing(line(5)) ? "" : line(5)
        return seen
    }

    /// Apple Vision's aesthetics score (macOS 15 and later): composition, light, subject.
    private static func aesthetics(of image: CGImage) -> Double {
        guard #available(macOS 15, *) else { return 0 }
        let request = VNCalculateImageAestheticsScoresRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let result = request.results?.first as? VNImageAestheticsScoresObservation else { return 0 }
        // (Its "utility" flag also catches dark, plain work shots, so only the score is used.)
        return Double(result.overallScore)
    }

    /// Only real visual techniques count as a look (the model sometimes puts other words there).
    static func techniques(in text: String) -> String {
        let known = ["silhouette", "flare", "depth of field", "bokeh", "symmetry", "leading line", "contrast", "shadow",
                     "low-key", "low key", "high-key", "high key", "golden", "backlit", "backlight", "reflection", "motion blur",
                     "framing", "frame within", "geometric", "pattern", "rim light", "haze", "fog", "neon", "dutch angle",
                     "low angle", "high angle", "top-down", "macro", "long exposure", "light beam", "god rays", "colour", "color"]
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
            .filter { phrase in known.contains { phrase.lowercased().contains($0) } }
            .joined(separator: ", ")
    }

    /// Faces Vision finds, and the best one's capture quality (in focus, eyes open, facing us).
    private static func faces(in image: CGImage) -> (count: Int, quality: Double) {
        let request = VNDetectFaceCaptureQualityRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let faces = (request.results ?? []).filter { $0.boundingBox.height > 0.05 }
        return (faces.count, Double(faces.compactMap(\.faceCaptureQuality).max() ?? 0))
    }

    /// Edge detail and exposure of a small grey version of the picture.
    private static func measure(_ picture: CGImage) -> (sharpness: Double, focus: Double, brightness: Double, blown: Double, crushed: Double) {
        let scale = min(1, 320 / Double(max(picture.width, picture.height)))
        let width = max(Int(Double(picture.width) * scale), 3), height = max(Int(Double(picture.height) * scale), 3)
        var grey = [UInt8](repeating: 0, count: width * height)
        grey.withUnsafeMutableBytes { bytes in
            if let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.interpolationQuality = .medium
                context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        var sum = 0.0, blown = 0, crushed = 0
        for value in grey {
            sum += Double(value)
            if value >= 250 { blown += 1 } else if value <= 6 { crushed += 1 }
        }
        let values = grey.map(Double.init)
        func laplacianVariance(_ g: [Double]) -> Double {
            var total = 0.0, squares = 0.0, count = 0.0
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    let value = 4 * g[i] - g[i - 1] - g[i + 1] - g[i - width] - g[i + width]
                    total += value; squares += value * value; count += 1
                }
            }
            let mean = total / max(count, 1)
            return squares / max(count, 1) - mean * mean
        }
        // The same picture slightly blurred (3×3 box).
        var blurred = values
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                blurred[i] = (values[i - width - 1] + values[i - width] + values[i - width + 1] + values[i - 1] + values[i]
                              + values[i + 1] + values[i + width - 1] + values[i + width] + values[i + width + 1]) / 9
            }
        }
        let sharpness = laplacianVariance(values)
        // Focus where it's sharpest: with a shallow depth of field the subject is crisp and the
        // rest soft on purpose, so the frame is judged by its best tiles (the second-best of 16,
        // so a single bright edge doesn't count).
        func tileFocus(_ tx: Int, _ ty: Int) -> Double {
            let x0 = max(1, tx * width / 4), x1 = min(width - 1, (tx + 1) * width / 4)
            let y0 = max(1, ty * height / 4), y1 = min(height - 1, (ty + 1) * height / 4)
            var a = 0.0, aa = 0.0, b = 0.0, bb = 0.0, n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * width + x
                    let v = 4 * values[i] - values[i - 1] - values[i + 1] - values[i - width] - values[i + width]
                    let w = 4 * blurred[i] - blurred[i - 1] - blurred[i + 1] - blurred[i - width] - blurred[i + width]
                    a += v; aa += v * v; b += w; bb += w * w; n += 1
                }
            }
            guard n > 0 else { return 0 }
            let detail = aa / n - (a / n) * (a / n), left = bb / n - (b / n) * (b / n)
            // A tile with almost no texture (sky, a wall) says nothing about focus.
            return detail > 25 ? 1 - left / detail : 0
        }
        var tiles: [Double] = []
        for ty in 0..<4 { for tx in 0..<4 { tiles.append(tileFocus(tx, ty)) } }
        let focus = tiles.sorted(by: >).dropFirst().first ?? 0
        let pixels = Double(grey.count)
        return (sharpness, focus, sum / pixels / 255, Double(blown) / pixels, Double(crushed) / pixels)
    }

    /// Scores every shot of a clip: usable (sharp for this camera, exposed, steady) times
    /// interesting (faces, smiles, action, a camera move).
    /// How much each kind of interest counts.
    struct Weights: Sendable {
        var faces = 0.15, smiling = 0.25, action = 0.25, activity = 0.1, look = 0.15, aesthetics = 0.25
        var cameraMove = 0.1, aerial = 0.05, closeUp = 0.0, strict = false

        static let standard = Weights()
    }

    private static func score(_ shots: inout [Shot]) {
        for index in shots.indices {
            let result = score(shots[index], weights: .standard)
            shots[index].quality?.score = result.score
            shots[index].quality?.problems = result.problems
        }
    }

    /// A shot's score for a kind of shoot: usable (sharp, exposed, steady, forgiving a deliberate
    /// look) times interesting (what that kind of video needs).
    static func score(_ shot: Shot, weights: Weights) -> (score: Double, problems: [Problem]) {
        guard var q = shot.quality else { return (0, []) }
        q.look = techniques(in: q.look)
        do {
            var problems: [Problem] = []
            var usable = 1.0
            // A deliberate look forgives what it explains: a silhouette or low-key shot is meant to
            // be dark, motion blur or a dreamy shot to be soft, a flare to blow out.
            let look = (q.look + " " + q.emotion).lowercased()
            // A beautiful picture (Vision's aesthetics) is forgiven more too.
            let beautiful = q.aesthetics > 0.3
            let meantDark = ["silhouette", "low-key", "low key", "moody", "night", "contrast", "shadow"].contains(where: look.contains)
            let meantSoft = ["motion blur", "dreamy", "bokeh", "shallow", "soft focus", "haze"].contains(where: look.contains)
            let meantBright = ["flare", "backlit", "glow", "bright", "high-key", "high key"].contains(where: look.contains)
            let strict = weights.strict
            if q.sharpnessShare < 0.35 { problems.append(.soft); usable *= meantSoft || beautiful ? (strict ? 0.5 : 0.8) : 0.25 }
            else { usable *= min(1, 0.55 + q.sharpnessShare * 0.5) }
            if q.blown > 0.25 { problems.append(.blown); usable *= meantBright || beautiful ? 0.9 : (strict ? 0.35 : 0.5) }
            if q.crushed > 0.5 || q.brightness < 0.08 { problems.append(.dark); usable *= meantDark || beautiful ? 0.9 : (strict ? 0.3 : 0.4) }
            // A smooth move's flow isn't shake.
            if q.shake > 0.15, shot.smooth != true { problems.append(.shaky); usable *= strict ? 0.45 : 0.6 }
            var interest = 0.35
            if q.faces > 0 { interest += weights.faces * (1 + 0.6 * q.faceQuality) }
            if q.smiling { interest += weights.smiling }
            interest += weights.action * min(q.action / 0.04, 1)
            if !q.activity.isEmpty { interest += weights.activity }
            // A shot with a look of its own is worth more than a plain one.
            if !q.look.isEmpty { interest += weights.look }
            interest += weights.aesthetics * max(0, q.aesthetics)
            switch shot.movement {
            case .pan, .tilt, .zoomIn, .zoomOut, .moving: interest += weights.cameraMove
            case .handheld, .whipPan, .still: break
            }
            // A clean gimbal or slider move is worth more: it can be speed-ramped in the edit.
            if shot.smooth == true { interest += weights.cameraMove }
            if shot.framing == .aerial { interest += weights.aerial }
            if shot.framing == .closeUp { interest += weights.closeUp }
            // Interest compared with the most a shot could have for this kind of video, so scores
            // spread out and the best stand out.
            let most = 0.35 + weights.faces * 1.6 + weights.smiling + weights.action + weights.activity + weights.look
                + weights.aesthetics + weights.cameraMove * 2 + max(weights.aerial, weights.closeUp)
            let share = min(1, interest / most)
            return (usable * (0.15 + 0.85 * share), problems)
        }
    }

    /// The best shots of a clip for a selects timeline: the highest scores, one per group of
    /// look-alike shots (several takes of the same thing), in the order they were filmed.
    static func selects(_ index: FileIndex, count: Int = 8) -> [Shot] {
        let scored = index.shots.filter { ($0.quality?.score ?? 0) >= 0.45 && !($0.quality?.problems.contains(.soft) ?? false) }
        var prints: [Double: VNFeaturePrintObservation] = [:]
        for shot in scored {
            let url = thumbnailURL(path: index.path, start: shot.start)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            if let print = request.results?.first { prints[shot.start] = print }
        }
        var chosen: [Shot] = []
        for shot in scored.sorted(by: { ($0.quality?.score ?? 0) > ($1.quality?.score ?? 0) }) {
            // Not another take of something already chosen.
            if let mine = prints[shot.start], chosen.contains(where: { other in
                guard let theirs = prints[other.start] else { return false }
                var distance: Float = 0
                try? mine.computeDistance(&distance, to: theirs)
                return distance < 0.55
            }) { continue }
            chosen.append(shot)
            if chosen.count == count { break }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    /// Vision's own labels, where the language model isn't available.
    private static func labels(of image: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.25 }.prefix(8)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    /// Shot size from the biggest face or person, and how many people are in it.
    private static func framing(of image: CGImage) -> (Framing, Int) {
        let faces = VNDetectFaceRectanglesRequest(), people = VNDetectHumanRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([faces, people])
        let faceHeight = (faces.results ?? []).map { Double($0.boundingBox.height) }.max() ?? 0
        let bodies = (people.results ?? []).filter { $0.confidence > 0.5 }
        let personHeight = bodies.map { Double($0.boundingBox.height) }.max() ?? 0
        if faceHeight > 0.28 { return (.closeUp, bodies.count) }
        if faceHeight > 0.09 || personHeight > 0.55 { return (.medium, bodies.count) }
        return (.wide, bodies.count)
    }

    /// Camera movement from optical flow between frames a moment apart: the average flow is a
    /// pan or tilt, flow away from (or towards) the middle is a push in (or pull out), flow that
    /// keeps changing direction is handheld. Speeds are in frame widths per second.
    private static func movement(generator: AVAssetImageGenerator, from start: Double, to end: Double) async
        -> (movement: Movement, shake: Double, action: Double, smooth: Bool) {
        let length = end - start
        // Pairs of frames 0.12 s apart, spread over the whole shot (a long move is judged whole).
        let gap = 0.12
        let count = min(12, max(3, Int(length / 0.3)))
        let span = max(0, length - 0.1 - gap - 0.05)
        let times = (0..<count).map { start + 0.05 + span * Double($0) / Double(max(count - 1, 1)) }
        guard length > 0.4 else { return (.still, 0, 0, false) }
        let small = smallGenerator(generator.asset, exact: true)
        var flows: [(dx: Double, dy: Double, zoom: Double, local: Double)] = []
        for time in times {
            guard let a = try? await small.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let b = try? await small.image(at: CMTime(seconds: time + gap, preferredTimescale: 600)).image,
                  let found = flow(from: a, to: b) else { continue }
            flows.append(found)
        }
        guard flows.count >= 2 else { return (.still, 0, 0, false) }
        let dx = flows.map { $0.dx / gap }, dy = flows.map { $0.dy / gap }, zoom = flows.map { $0.zoom / gap }
        let action = flows.map(\.local).sorted()[flows.count / 2] / gap
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
        func spread(_ v: [Double]) -> Double { let m = mean(v); return sqrt(v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)) }
        let mx = mean(dx), my = mean(dy), mz = mean(zoom)
        let peak = zip(dx, dy).map { max(abs($0), abs($1)) }.max() ?? 0
        let jitter = spread(dx) + spread(dy)
        let movement: Movement
        var main: [Double] = []
        if peak > 0.5, length < 3 { movement = .whipPan }
        else if abs(mz) > 0.04, abs(mz) > (abs(mx) + abs(my)) * 0.5 { movement = mz > 0 ? .zoomIn : .zoomOut; main = zoom }
        else if abs(mx) > 0.03, abs(mx) > abs(my) * 1.5, jitter < abs(mx) * 1.2 { movement = .pan; main = dx }
        else if abs(my) > 0.03, abs(my) > abs(mx) * 1.5, jitter < abs(my) * 1.2 { movement = .tilt; main = dy }
        else if jitter > 0.08 { movement = .handheld }
        else if abs(mx) + abs(my) + abs(mz) > 0.03 { movement = .moving }
        else { movement = .still }
        // Moving forward or back (low, on a gimbal) also slides the picture up or down as it goes:
        // that's the move, not shake. Only the sideways wobble counts then.
        let isPush = movement == .zoomIn || movement == .zoomOut
        let shake = isPush ? spread(dx) * 2 : jitter
        // Smooth: the move goes one way all along at an even speed, without shake on top.
        var smooth = false
        if !main.isEmpty, length >= 1.5 {
            let m = mean(main)
            let sameWay = main.filter { $0 * m > 0 }.count >= main.count - 2
            let even = spread(main) < abs(m) * 0.8
            let steady = isPush ? shake < 0.12 : spread(movement == .pan ? dy : dx) < 0.04
            smooth = sameWay && even && steady
        }
        return (movement, shake, action, smooth)
    }

    private static func smallGenerator(_ asset: AVAsset, exact: Bool) -> AVAssetImageGenerator {
        let small = AVAssetImageGenerator(asset: asset)
        small.appliesPreferredTrackTransform = true
        small.maximumSize = CGSize(width: 256, height: 256)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.04, preferredTimescale: 600)
        small.requestedTimeToleranceBefore = tolerance
        small.requestedTimeToleranceAfter = tolerance
        return small
    }

    /// The camera moves within a shot (push-in, pull-out, pan, tilt): where each starts and ends,
    /// from the camera's motion four times a second. The parts between are holds or other motion.
    static func moves(in asset: AVAsset, from start: Double, to end: Double) async -> [(start: Double, end: Double, isMove: Bool)] {
        let whole = [(start: start, end: end, isMove: false)]
        guard end - start >= 2.5 else { return whole }
        let step = 0.25, gap = 0.12
        let small = smallGenerator(asset, exact: false)
        var samples: [(time: Double, dx: Double, dy: Double, zoom: Double)] = []
        var t = start + 0.05
        while t + gap < end - 0.05 {
            if let a = try? await small.image(at: CMTime(seconds: t, preferredTimescale: 600)).image,
               let b = try? await small.image(at: CMTime(seconds: t + gap, preferredTimescale: 600)).image,
               let found = flow(from: a, to: b) {
                samples.append((t, found.dx / gap, found.dy / gap, found.zoom / gap))
            }
            t += step
        }
        guard samples.count >= 6 else { return whole }
        // Averaged over about a second, so shake and single odd frames don't count as moves.
        func smoothed(_ value: (Int) -> Double) -> [Double] {
            samples.indices.map { i in
                let range = max(0, i - 2)...min(samples.count - 1, i + 2)
                return range.map(value).reduce(0, +) / Double(range.count)
            }
        }
        let x = smoothed { samples[$0].dx }, y = smoothed { samples[$0].dy }, z = smoothed { samples[$0].zoom }
        var taken = [Bool](repeating: false, count: samples.count)
        var found: [(from: Int, to: Int)] = []
        // Runs where a value stays clearly one way; a move needs a real peak and some length
        // (a gimbal drifting a little isn't a move).
        func runs(_ values: [Double], above: Double, peak: Double, length: Double, dominant: (Int) -> Bool) {
            var i = 0
            while i < values.count {
                guard !taken[i], abs(values[i]) > above, dominant(i) else { i += 1; continue }
                let sign = values[i] > 0
                var j = i
                while j + 1 < values.count, !taken[j + 1], abs(values[j + 1]) > above, (values[j + 1] > 0) == sign { j += 1 }
                let top = values[i...j].map(abs).max() ?? 0
                if top >= peak, Double(j - i + 1) * step >= length {
                    found.append((i, j))
                    for k in i...j { taken[k] = true }
                }
                i = j + 1
            }
        }
        // Push-ins and pull-outs first: moving forward low also tilts the picture, which isn't a tilt.
        runs(z, above: 0.05, peak: 0.15, length: 1.0) { _ in true }
        runs(x, above: 0.05, peak: 0.1, length: 1.5) { abs(x[$0]) > abs(y[$0]) }
        runs(y, above: 0.05, peak: 0.1, length: 1.5) { abs(y[$0]) > abs(x[$0]) }
        guard !found.isEmpty else { return whole }
        var parts: [(start: Double, end: Double, isMove: Bool)] = []
        var cursor = start
        for move in found.sorted(by: { $0.from < $1.from }) {
            var from = max(cursor, move.from == 0 ? start : samples[move.from].time - step / 2)
            let to = move.to == samples.count - 1 ? end : min(end, samples[move.to].time + step / 2 + gap)
            // A sliver of under a second between moves (or before the first) joins them.
            if from - cursor >= 1 { parts.append((cursor, from, false)) }
            else if parts.isEmpty { from = cursor }
            else { parts[parts.count - 1].end = from }
            parts.append((from, to, true))
            cursor = to
        }
        if end - cursor >= 1 { parts.append((cursor, end, false)) } else { parts[parts.count - 1].end = end }
        return parts
    }

    /// The average flow (share of the frame per frame pair) and the zoom (outward flow per pixel
    /// of distance from the middle) between two frames.
    private static func flow(from a: CGImage, to b: CGImage) -> (dx: Double, dy: Double, zoom: Double, local: Double)? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: b)
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try? VNImageRequestHandler(cgImage: a).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        var sx = 0.0, sy = 0.0, radial = 0.0, n = 0.0, rn = 0.0, squares = 0.0
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in stride(from: 4, to: h - 4, by: 4) {
            let pixels = (base + y * row).assumingMemoryBound(to: Float.self)
            for x in stride(from: 4, to: w - 4, by: 4) {
                let fx = Double(pixels[x * 2]), fy = Double(pixels[x * 2 + 1])
                sx += fx; sy += fy; n += 1
                squares += fx * fx + fy * fy
                let rx = Double(x) - cx, ry = Double(y) - cy, d2 = rx * rx + ry * ry
                if d2 > Double(w * w) / 64 { radial += (fx * rx + fy * ry) / d2; rn += 1 }
            }
        }
        guard n > 0 else { return nil }
        // Movement within the picture: how much the flow differs from the camera's own move
        // (zooming spreads flow outwards, which isn't action, so that part is taken off).
        let mx = sx / n, my = sy / n
        let spread = sqrt(max(0, squares / n - mx * mx - my * my)) / Double(w)
        let zoomSpread = abs(radial / max(rn, 1)) * 0.35
        return (mx / Double(w), my / Double(h), radial / max(rn, 1), max(0, spread - zoomSpread))
    }

    private static func saveThumbnail(_ image: CGImage, to url: URL, width: Double = 320) {
        let ci = CIImage(cgImage: image)
        let scale = min(1, width / max(ci.extent.width, 1))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        try? CIContext().writeJPEGRepresentation(of: small, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.75])
    }

    // MARK: - Searching

    /// Shots matching words like "drone shot of forest" or "whip pan": meaning (sentence
    /// embeddings) plus the words themselves, best first.
    static func search(_ query: String, in indexes: [FileIndex], movement: Movement? = nil, framing: Framing? = nil,
                       limit: Int = 200) -> [Hit] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init)
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let queryVector = words.isEmpty ? nil : embedding?.vector(for: query.lowercased())
        var hits: [Hit] = []
        for index in indexes {
            for shot in index.shots {
                if let movement, shot.movement != movement { continue }
                if let framing, shot.framing != framing { continue }
                guard !words.isEmpty else {
                    hits.append(Hit(path: index.path, shot: shot, score: 0))
                    continue
                }
                let text = (shot.description + " " + shot.keywords.joined(separator: " ") + " " + shot.framing.words + " " + shot.movement.words
                            + (shot.smooth == true ? " smooth gimbal slider speed ramp" : "")).lowercased()
                let matched = words.filter { word in text.contains(word) }.count
                var score = Double(matched) / Double(words.count)
                if let queryVector, let vector = shot.embedding, vector.count == queryVector.count {
                    score += cosine(queryVector, vector.map(Double.init)) * 1.2
                }
                if score > 0.45 { hits.append(Hit(path: index.path, shot: shot, score: score)) }
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}
