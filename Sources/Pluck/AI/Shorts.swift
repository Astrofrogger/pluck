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
        /// nil: no captions.
        var captions: CaptionDesign? = CaptionDesign()
        var framing: FramingChoice = .automatic
        /// The spoken language, when the user chose it (otherwise guessed).
        var language: Locale?
    }

    enum FramingChoice: String, CaseIterable, Identifiable, Sendable {
        case automatic, whole, crop
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: String(localized: "Automatic")
            case .whole: String(localized: "Whole picture")
            case .crop: String(localized: "Crop to fill")
            }
        }
        var detail: String {
            switch self {
            case .automatic: String(localized: "Follows the speaker or subject, and shows titles whole.")
            case .whole: String(localized: "The full picture over a blurred fill, for videos with a lot of text and graphics.")
            case .crop: String(localized: "Always fills the frame, steady on the subject of each shot.")
            }
        }
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
            let count = OnDeviceWriter.size(of: line)
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

    // MARK: - Framing, shot by shot

    /// How one shot of the short is framed.
    struct Shot: Sendable {
        var start: Double
        var end: Double
        enum Framing: Sendable, Equatable {
            /// A 9:16 window centred here (0…1 across the source).
            case crop(Double)
            /// The whole picture over a blurred fill: titles, maps, wide scenes.
            case fit
        }
        var framing: Framing
    }

    /// Cuts in the clip, in seconds from its start, found by ffmpeg's scene detection.
    static func cuts(in file: URL, from start: Double, to end: Double, ffmpeg: String) async -> [Double] {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "error", "-ss", String(start), "-t", String(end - start), "-i", file.path, "-an",
                           "-vf", "scale=320:-2,scdet=threshold=6,metadata=print:key=lavfi.scd.time:file=-", "-f", "null", "-"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                line.hasPrefix("lavfi.scd.time=") ? Double(line.dropFirst("lavfi.scd.time=".count)) : nil
            }
        }.value
    }

    /// One framing per shot, held still for the whole shot like an editor would: on the face or
    /// person if there is one, otherwise on the main subject; shots with big text wider than a
    /// vertical frame (titles, lower thirds) are shown whole instead of cut off.
    static func shots(_ file: URL, from start: Double, to end: Double, cuts: [Double], cropFraction: Double,
                      choice: FramingChoice = .automatic) async -> [Shot] {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        // A look at the picture every half second: what's in it, and a tiny greyscale copy to
        // notice changes that aren't hard cuts (dissolves, animated transitions).
        let duration = end - start
        let step = 0.5
        var samples: [(time: Double, look: Look, thumb: [Float])] = []
        var t = step / 2
        while t < duration {
            if let image = try? await generator.image(at: CMTime(seconds: start + t, preferredTimescale: 600)).image {
                samples.append((t, look(at: image), thumbnail(image)))
            }
            t += step
        }
        // Hard cuts from ffmpeg, plus big changes between neighbouring samples.
        var bounds = cuts.filter { $0 > 0.2 && $0 < duration - 0.2 }
        for i in samples.indices.dropFirst() {
            let a = samples[i - 1], b = samples[i]
            let between = (a.time + b.time) / 2
            guard !bounds.contains(where: { $0 > a.time && $0 < b.time }) else { continue }
            if difference(a.thumb, b.thumb) > 0.18 { bounds.append(between) }
        }
        bounds = [0] + bounds.sorted() + [duration]

        var shots: [Shot] = []
        for index in 0..<(bounds.count - 1) {
            let a = bounds[index], b = bounds[index + 1]
            guard b - a > 0.01 else { continue }
            var looks = samples.filter { $0.time >= a && $0.time < b }.map(\.look)
            if looks.isEmpty, let image = try? await generator.image(at: CMTime(seconds: start + (a + b) / 2, preferredTimescale: 600)).image {
                looks = [look(at: image)]
            }
            var framing = framing(for: looks, cropFraction: cropFraction)
            if choice == .crop, framing == .fit {
                framing = .crop(looks.compactMap { $0.subject.map { Double($0.midX) } }.first ?? 0.5)
            }
            shots.append(Shot(start: a, end: b, framing: framing))
        }
        return shots
    }

    /// 32×18 greyscale, for comparing frames.
    private static func thumbnail(_ image: CGImage) -> [Float] {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels.map { Float($0) / 255 } : []
    }

    /// Mean absolute difference between two thumbnails (0 same … 1 opposite).
    private static func difference(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count)
    }

    /// What Vision sees in one frame.
    private struct Look {
        var face: Double?
        var person: Double?
        var subject: CGRect?
        var textWidth: Double
    }

    private static func look(at image: CGImage) -> Look {
        let handler = VNImageRequestHandler(cgImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        let people = VNDetectHumanRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let text = VNDetectTextRectanglesRequest()
        try? handler.perform([faces, people, saliency, text])
        let face = faces.results?.filter { $0.boundingBox.area > 0.003 }.max { $0.boundingBox.area < $1.boundingBox.area }
        let person = people.results?.filter { $0.confidence > 0.5 && $0.boundingBox.area > 0.02 }.max { $0.boundingBox.area < $1.boundingBox.area }
        let objects = (saliency.results?.first)?.salientObjects ?? []
        var subject: CGRect?
        for object in objects { subject = subject.map { $0.union(object.boundingBox) } ?? object.boundingBox }
        // Big text only (titles, lower thirds), not a sign in the background.
        let bigText = (text.results ?? []).filter { $0.boundingBox.height > 0.05 }
        let textSpan = bigText.isEmpty ? 0 : Double(bigText.map(\.boundingBox.maxX).max()! - bigText.map(\.boundingBox.minX).min()!)
        return Look(face: face.map { Double($0.boundingBox.midX) }, person: person.map { Double($0.boundingBox.midX) },
                    subject: subject, textWidth: textSpan)
    }

    private static func framing(for looks: [Look], cropFraction: Double) -> Shot.Framing {
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let clamp = { (x: Double) in min(max(x, cropFraction / 2), 1 - cropFraction / 2) }
        // Text wider than the vertical window would be cut off: show the whole frame.
        if looks.contains(where: { $0.textWidth > cropFraction * 1.15 }) { return .fit }
        if let x = median(looks.compactMap(\.face)) { return .crop(clamp(x)) }
        if let x = median(looks.compactMap(\.person)) { return .crop(clamp(x)) }
        // Wide scenes (drone shots, crowds) still crop well on their centre of interest; only
        // text is shown whole, because cut-off words look broken.
        let subjects = looks.compactMap(\.subject)
        if let x = median(subjects.map { Double($0.midX) }) { return .crop(clamp(x)) }
        return .crop(0.5)
    }

    /// The ffmpeg filter graph for one short (input [0:v], output [out]): each shot cropped at
    /// its own fixed position (switched exactly on the cuts) or shown whole over a blurred fill,
    /// scaled to 1080×1920, with the captions on top.
    static func filterGraph(sourceWidth width: Int, sourceHeight height: Int, shots: [Shot],
                            commandFile: URL, captions: URL?) throws -> String {
        let cropWidth = (Double(height) * 9 / 16).rounded(.down)
        let captionFilter = captions.map { "," + Captions.filter($0) } ?? ""
        guard Double(width) > cropWidth * 1.05 else {
            // Already vertical: fill the frame.
            return "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setsar=1\(captionFilter)[out]"
        }
        let fraction = cropWidth / Double(width)
        let x = { (centre: Double) in min(max((centre - fraction / 2) * Double(width), 0), Double(width) - cropWidth).rounded() }
        // Fit shots keep the last crop position underneath (hidden), so nothing slides there.
        var positions: [(Double, Double)] = []
        var last = 0.5
        for shot in shots {
            if case .crop(let centre) = shot.framing { last = centre }
            positions.append((shot.start, x(last)))
        }
        let commands = positions.map { String(format: "%.3f crop@frame x %.0f;", $0.0, $0.1) }.joined(separator: "\n")
        try commands.write(to: commandFile, atomically: true, encoding: .utf8)
        let fits = shots.filter { $0.framing == .fit }

        var graph: [String] = []
        graph.append(fits.isEmpty ? "[0:v]null[c]" : "[0:v]split=2[c][f]")
        graph.append("[c]sendcmd=f=\(FFmpegFilter.path(commandFile)),crop@frame=w=\(Int(cropWidth)):h=\(height):x=\(Int(positions.first?.1 ?? 0)):y=0,scale=1080:1920:flags=lanczos,setsar=1[cropped]")
        if fits.isEmpty {
            graph.append("[cropped]null\(captionFilter)[out]")
        } else {
            graph.append("[f]split=2[f1][f2]")
            graph.append("[f1]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=36,eq=brightness=-0.12:saturation=1.1[bg]")
            graph.append("[f2]scale=1080:-2:flags=lanczos[fg]")
            graph.append("[bg][fg]overlay=(W-w)/2:(H-h)/2,setsar=1[fitted]")
            let enable = fits.map { String(format: "between(t\\,%.3f\\,%.3f)", $0.start, $0.end - 0.001) }.joined(separator: "+")
            graph.append("[cropped][fitted]overlay=enable='\(enable)'\(captionFilter)[out]")
        }
        return graph.joined(separator: ";")
    }

    /// Caption file for one short, in Pluck's caption style.
    static func captionFile(for moment: Moment, transcript: Transcript, design: CaptionDesign, cuts: [Double], to url: URL) throws {
        let words = transcript.words.filter { $0.s >= moment.start - 0.05 && $0.e <= moment.end + 0.2 }
        try Captions.short(words: words, from: moment.start, cuts: cuts, design: design)
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

