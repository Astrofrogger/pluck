import AVFoundation
import AppKit
import Foundation
import FoundationModels
import Vision

/// Shorts: vertical 9:16 clips from a long video, made on this Mac with local AI. The best
/// moments are chosen from the transcript, the picture follows the speaker or subject, and
/// the words light up as they're spoken.
enum Shorts {
    struct Options: Sendable {
        var count = 3
        var length: Length = .medium
        var captions: CaptionStyle = .animated
        var followSubject = true
    }

    enum Length: String, CaseIterable, Identifiable, Sendable {
        case short, medium, long
        var id: String { rawValue }
        var range: ClosedRange<Double> {
            switch self {
            case .short: 15...30
            case .medium: 30...45
            case .long: 45...60
            }
        }
        var label: String {
            switch self {
            case .short: String(localized: "15–30 seconds")
            case .medium: String(localized: "30–45 seconds")
            case .long: String(localized: "45–60 seconds")
            }
        }
    }

    enum CaptionStyle: String, CaseIterable, Identifiable, Sendable {
        case animated, plain, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .animated: String(localized: "Word by word")
            case .plain: String(localized: "Plain")
            case .none: String(localized: "None")
            }
        }
    }

    struct Moment: Sendable {
        var start: Double
        var end: Double
        var title: String
    }

    // MARK: - Choosing moments

    @available(macOS 26, *)
    @Generable
    struct Candidates {
        @Guide(description: "The best moments in this part for a short vertical video, most engaging first.", .count(1...3))
        var moments: [Candidate]
    }

    @available(macOS 26, *)
    @Generable
    struct Candidate {
        @Guide(description: "Timestamp of the line where the moment starts, exactly as written, like 03:15.")
        var start: String
        @Guide(description: "Timestamp of the last line of the moment, exactly as written.")
        var end: String
        @Guide(description: "A catchy title of at most 6 words.")
        var title: String
        @Guide(description: "How strong this moment is on its own, from 1 to 10.", .range(1...10))
        var score: Int
    }

    /// The moments to cut, chosen by local AI from what's said when Apple Intelligence is on,
    /// otherwise by where the speech is densest. Snapped to whole sentences and kept apart.
    static func moments(in transcript: Transcript, options: Options) async -> [Moment] {
        let cues = transcript.cues(maxCharacters: 160, maxDuration: 12)
        guard !cues.isEmpty else { return [] }
        var picked: [(Moment, Int)] = []
        if #available(macOS 26, *), LocalAI.canSummarize {
            picked = (try? await aiMoments(cues, title: transcript.title, options: options)) ?? []
        }
        if picked.isEmpty { picked = densestMoments(cues, options: options) }

        // Best first, no overlaps, then back in time order.
        var chosen: [Moment] = []
        for (moment, _) in picked.sorted(by: { $0.1 > $1.1 }) {
            let fitted = fit(moment, cues: cues, range: options.length.range)
            if chosen.contains(where: { $0.start < fitted.end && fitted.start < $0.end }) { continue }
            chosen.append(fitted)
            if chosen.count == options.count { break }
        }
        return chosen.sorted { $0.start < $1.start }
    }

    @available(macOS 26, *)
    private static func aiMoments(_ cues: [Transcript.Cue], title: String, options: Options) async throws -> [(Moment, Int)] {
        let lines = cues.map { "[\(OnDeviceWriter.clock($0.start))] \($0.text)" }
        var parts: [[String]] = [[]]
        var words = 0
        for line in lines {
            let count = line.split(separator: " ").count
            if words + count > 700, !(parts.last ?? []).isEmpty { parts.append([]); words = 0 }
            parts[parts.count - 1].append(line)
            words += count
        }
        var found: [(Moment, Int)] = []
        for part in parts {
            let session = LanguageModelSession(instructions: """
                You are a video editor cutting short vertical clips (Shorts, Reels, TikTok) from a \
                longer video. Pick moments that make sense on their own and grab attention in the \
                first seconds: a strong claim, a reveal, a joke, a useful tip or a story with a \
                payoff. Each moment should last about \(Int(options.length.range.lowerBound)) to \
                \(Int(options.length.range.upperBound)) seconds. Write titles in the language of \
                the transcript.
                """)
            let reply = try await session.respond(to: "Video: \(title)\nTranscript:\n\(part.joined(separator: "\n"))",
                                                  generating: Candidates.self)
            for candidate in reply.content.moments {
                guard let start = OnDeviceWriter.seconds(from: candidate.start),
                      let end = OnDeviceWriter.seconds(from: candidate.end) else { continue }
                found.append((Moment(start: start, end: max(end, start + 1), title: candidate.title), candidate.score))
            }
        }
        return found
    }

    /// Without Apple Intelligence: the windows with the most words per second.
    private static func densestMoments(_ cues: [Transcript.Cue], options: Options) -> [(Moment, Int)] {
        let target = (options.length.range.lowerBound + options.length.range.upperBound) / 2
        return cues.indices.compactMap { index in
            let start = cues[index].start
            let window = cues[index...].prefix { $0.end - start <= target }
            guard let last = window.last, last.end - start >= options.length.range.lowerBound else { return nil }
            let words = window.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let firstWords = cues[index].text.split(separator: " ").prefix(4).joined(separator: " ")
            return (Moment(start: start, end: last.end, title: firstWords), Int(Double(words) / (last.end - start) * 100))
        }
    }

    /// Starts on a line's start, ends on a line's end, and lasts within the chosen range.
    private static func fit(_ moment: Moment, cues: [Transcript.Cue], range: ClosedRange<Double>) -> Moment {
        let first = cues.min { abs($0.start - moment.start) < abs($1.start - moment.start) } ?? cues[0]
        var end = cues.filter { $0.start >= first.start }.min { abs($0.end - moment.end) < abs($1.end - moment.end) }?.end ?? moment.end
        if end - first.start < range.lowerBound {
            end = cues.first { $0.end - first.start >= range.lowerBound }?.end ?? first.start + range.lowerBound
        }
        if end - first.start > range.upperBound {
            end = cues.last { $0.start >= first.start && $0.end - first.start <= range.upperBound }?.end ?? first.start + range.upperBound
        }
        return Moment(start: first.start, end: max(end, first.start + 3), title: moment.title)
    }

    // MARK: - Following the subject

    /// Where the 9:16 window should be, as the horizontal centre (0…1) over time, sampled every
    /// 0.25 s. Faces first, then people, then whatever stands out; smoothed like a camera
    /// operator would (hold still, ease toward the subject, cut on scene changes).
    static func track(_ file: URL, from start: Double, to end: Double, cropWidth: Double) async -> [(time: Double, x: Double)] {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let step = 0.25
        let times = stride(from: start, through: end, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }

        var raw: [(Double, Double?)] = []
        for time in times {
            guard let image = try? await generator.image(at: time).image else { raw.append((time.seconds - start, nil)); continue }
            raw.append((time.seconds - start, subjectCentre(in: image)))
        }
        // Fill gaps with the last known position (or the middle).
        var targets: [Double] = []
        var last = 0.5
        for (_, x) in raw {
            if let x { last = x }
            targets.append(last)
        }
        // A camera that holds still while the subject stays near the middle of the frame,
        // eases toward it otherwise, and jumps on a cut.
        let halfWindow = cropWidth / 2
        let clamp = { (x: Double) in min(max(x, halfWindow), 1 - halfWindow) }
        var camera = clamp(targets.first ?? 0.5)
        var path: [(Double, Double)] = []
        for (index, target) in targets.enumerated() {
            let goal = clamp(target)
            let distance = goal - camera
            if abs(distance) > 0.3 {
                camera = goal                                   // scene change: cut
            } else if abs(distance) > cropWidth * 0.18 {
                camera += distance.sign == .minus ? -min(abs(distance) * 0.35, 0.35 * step) : min(abs(distance) * 0.35, 0.35 * step)
            }
            path.append((raw[index].0, camera))
        }
        return path
    }

    /// The horizontal centre (0…1) of the most important thing in the frame, or nil.
    private static func subjectCentre(in image: CGImage) -> Double? {
        let handler = VNImageRequestHandler(cgImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, people, saliency])
        if let face = faces.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }), face.boundingBox.area > 0.002 {
            return face.boundingBox.midX
        }
        if let person = people.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }), person.confidence > 0.5 {
            return person.boundingBox.midX
        }
        if let object = (saliency.results?.first)?.salientObjects?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) {
            return object.boundingBox.midX
        }
        return nil
    }
}

extension Shorts {
    /// The ffmpeg filter graph for one short: the moving 9:16 window (from `path`, as written to
    /// a sendcmd file), scaling to 1080×1920 and the captions.
    static func filters(sourceWidth width: Int, sourceHeight height: Int, path: [(time: Double, x: Double)]?,
                        commandFile: URL, captions: URL?) throws -> [String] {
        var filters: [String] = []
        let cropWidth = (Double(height) * 9 / 16).rounded(.down)
        if Double(width) > cropWidth * 1.05 {
            let fraction = cropWidth / Double(width)
            var startX = ((Double(width) - cropWidth) / 2).rounded()
            if let path, !path.isEmpty {
                let pixels = path.map { (time: $0.time, x: min(max((($0.x - fraction / 2) * Double(width)).rounded(), 0), Double(width) - cropWidth)) }
                startX = pixels[0].x
                let commands = pixels.map { String(format: "%.2f crop@reframe x %.0f;", $0.time, $0.x) }.joined(separator: "\n")
                try commands.write(to: commandFile, atomically: true, encoding: .utf8)
                filters.append("sendcmd=f=\(FFmpegFilter.path(commandFile))")
            }
            filters.append(String(format: "crop@reframe=w=%.0f:h=%d:x=%.0f:y=0", cropWidth, height, startX))
        }
        filters.append("scale=1080:1920:flags=lanczos,setsar=1")
        if let captions { filters.append("ass=\(FFmpegFilter.path(captions)):fontsdir=/System/Library/Fonts") }
        return filters
    }

    /// Caption cues for one moment: short lines for word-by-word captions, longer for plain.
    static func captionFile(for moment: Moment, transcript: Transcript, style: CaptionStyle, to url: URL) throws {
        let words = transcript.words.filter { $0.s >= moment.start - 0.05 && $0.e <= moment.end + 0.2 }
        let cues = Transcript(id: "", title: "", filePath: "", language: transcript.language, created: .now, words: words)
            .cues(maxCharacters: style == .animated ? 26 : 60, maxDuration: style == .animated ? 2.6 : 5)
        try Transcript.ass(cues, words: words, width: 1080, height: 1920, karaoke: style == .animated, offset: moment.start)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

