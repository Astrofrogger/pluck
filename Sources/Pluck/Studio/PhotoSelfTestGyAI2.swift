import AVFoundation
import AppKit
import CoreImage

/// Shorts review, Privacy Blur fixes and corrected caption words (-PluckScreenshotOnly gyai2):
/// a corrected word keeps its timing, is saved and reaches a short's burned-in captions through
/// the transcript every tool reads; Shorts keep to a picked range (one that fits is the short as
/// picked), offer more moments to swap in and keep nudges inside the video, and render exactly
/// the reviewed moments; a region drawn in Privacy Blur is followed through the clip, covered in
/// the mask, and saved as a ProRes black-and-white matte.
extension PhotoSelfTest {
    static func gyAI2Test() async {
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg") else {
            return check("gyai2: ffmpeg", false, "no ffmpeg")
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("GyAI2Test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // MARK: Correcting words
        let three = [Transcript.Word(s: 1, e: 1.4, t: " hello"), Transcript.Word(s: 1.5, e: 1.9, t: " wrld"), Transcript.Word(s: 2, e: 2.6, t: " again.")]
        let base = Transcript(id: UUID().uuidString, title: "Test", filePath: "/nowhere", language: "en-US", created: .now, words: three)
        let one = base.correctingWords(1...1, to: "world")
        check("gyai2: one word corrected, timing kept", one.words.map(\.t) == [" hello", " world", " again."] && one.words[1].s == 1.5 && one.words[1].e == 1.9,
              "\(one.words)")
        let more = base.correctingWords(0...1, to: "Hi there big")
        check("gyai2: more words share the stretch", more.words.count == 4 && more.words[0].s == 1 && more.words[2].e == 1.9
              && more.words[0].t == " Hi" && more.words[1].t == " there" && zip(more.words, more.words.dropFirst()).allSatisfy { $0.e <= $1.s + 1e-9 },
              "\(more.words)")
        check("gyai2: empty correction changes nothing", base.correctingWords(0...0, to: "  ").words.map(\.t) == base.words.map(\.t))

        // MARK: Shorts moments
        // 120 s of speech: a word every 0.5 s, a sentence every 5 s.
        var words: [Transcript.Word] = []
        for i in 0..<240 {
            let s = Double(i) * 0.5
            words.append(Transcript.Word(s: s, e: s + 0.4, t: " word\(i)" + (i % 10 == 9 ? "." : "")))
        }
        let talk = Transcript(id: UUID().uuidString, title: "Talk", filePath: "/nowhere", language: "en-US", duration: 120, created: .now, words: words)
        var options = Shorts.Options()
        options.count = 2
        options.length = .short
        options.range = 40...100
        let inRange = await Shorts.candidates(in: talk, options: options, useAI: false)
        let overlaps = inRange.indices.contains { i in inRange.indices.contains { j in i != j && inRange[i].start < inRange[j].end && inRange[j].start < inRange[i].end } }
        check("gyai2: shorts stay in the picked range", !inRange.isEmpty && inRange.allSatisfy { $0.start >= 39.9 && $0.end <= 100.1 },
              inRange.map { "\($0.start)–\($0.end)" }.joined(separator: ", "))
        check("gyai2: more moments to swap in, none overlapping", inRange.count > options.count && !overlaps, "\(inRange.count)")
        options.range = 50.2...74.6
        let exact = await Shorts.candidates(in: talk, options: options, useAI: false)
        check("gyai2: a range that fits is the short as picked", exact.count == 1 && exact[0].start == 50.2 && exact[0].end == 74.6,
              exact.map { "\($0.start)–\($0.end)" }.joined(separator: ", "))
        let moment = Shorts.Moment(start: 1, end: 10, title: "A")
        check("gyai2: nudges stay inside the video and 3 s long",
              Shorts.nudged(moment, start: true, by: -2, duration: 20).start == 0
              && Shorts.nudged(moment, start: true, by: 8, duration: 20).start == 7
              && Shorts.nudged(Shorts.Moment(start: 15, end: 19.5, title: "B"), start: false, by: 1, duration: 20).end == 20
              && Shorts.nudged(moment, start: false, by: -8, duration: 20).end == 4)

        // MARK: A clip: a textured box moving across, with sound
        let W = 640.0, boxW = 80.0, y = 140.0
        let truth = { (t: Double) -> Double in (100 + 75 * t + boxW / 2) / W }   // box centre, 0…1
        let clip = folder.appendingPathComponent("clip.mov")
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=0x404040:s=640x360:r=25:d=12", "-f", "lavfi", "-i", "testsrc2=s=80x80:r=25:d=12",
            "-f", "lavfi", "-i", "sine=f=440:r=48000:d=12",
            "-filter_complex", "[0][1]overlay=x='100+75*min(t\\,4)':y=\(Int(y)):shortest=1[v]", "-map", "[v]", "-map", "2", "-t", "12",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-timecode", "01:00:00:00", clip.path])
        guard FileManager.default.fileExists(atPath: clip.path) else { return check("gyai2: test clip made", false, "ffmpeg failed") }

        // MARK: Privacy Blur: a drawn region, followed
        let drawn = CGRect(x: truth(2) - boxW / W / 2, y: 1 - (y + boxW) / 360, width: boxW / W, height: boxW / 360)
        let track = await PrivacyBlur.follow(clip, box: drawn, at: 2, step: 0.125, id: 99)
        let early = track.box(at: 0.5, hold: 0.125), late = track.box(at: 3.5, hold: 0.125)
        check("gyai2: drawn region followed both ways", track.manual && track.start <= 0.5 && track.end >= 3.5
              && early.map { abs($0.midX - truth(0.5)) < 0.04 } == true && late.map { abs($0.midX - truth(3.5)) < 0.04 } == true,
              "\(track.start)–\(track.end), at 0.5 \(early.map { $0.midX } ?? -1) vs \(truth(0.5)), at 3.5 \(late.map { $0.midX } ?? -1) vs \(truth(3.5))")

        let analysis = PrivacyBlur.Analysis()
        analysis.faces = [track]
        let painter = PrivacyBlur.Painter(analysis: analysis, keepSharp: [], blurText: false, style: .blur)
        let extent = CGRect(x: 0, y: 0, width: 640, height: 360)
        let mask = painter.mask(extent, at: 2)
        let centre = CGPoint(x: truth(2) * 640, y: 360 - y - boxW / 2)
        check("gyai2: mask white on the region, black elsewhere",
              mask.map { brightness($0, at: centre) > 0.9 && brightness($0, at: CGPoint(x: 20, y: 20)) < 0.1 } == true)
        check("gyai2: kept sharp: nothing hidden",
              PrivacyBlur.Painter(analysis: analysis, keepSharp: [99], blurText: false, style: .blur).mask(extent, at: 2) == nil)

        // MARK: The matte for Resolve
        let matte = folder.appendingPathComponent("clip (matte).mov")
        do {
            try await AIStudio.writeMatte(clip, to: matte, analysis: analysis, keepSharp: [], blurText: false) { _ in }
            let asset = AVURLAsset(url: matte)
            let video = try await asset.loadTracks(withMediaType: .video).first
            let codec = try await video?.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
            let length = try await asset.load(.duration).seconds
            check("gyai2: matte is ProRes 4444, as long as the clip", codec == kCMVideoCodecType_AppleProRes4444 && abs(length - 12) < 0.2,
                  "codec \(codec ?? 0), \(length) s")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(seconds: 2, preferredTimescale: 600)).image
            let picture = CIImage(cgImage: frame)
            check("gyai2: matte white where it blurs", brightness(picture, at: centre) > 0.85 && brightness(picture, at: CGPoint(x: 20, y: 20)) < 0.1)
            let probe = await DeliveryCheck.output(manager.tool("ffprobe") ?? "", ["-v", "error", "-show_entries", "format_tags=timecode:stream_tags=timecode",
                                                                                  "-of", "default=nw=1", matte.path])
            check("gyai2: matte keeps the start timecode", probe.contains("01:00:00:00"), probe)
        } catch {
            check("gyai2: matte written", false, error.localizedDescription)
        }

        // MARK: Corrected words reach a short's captions, and reviewed moments are what's made
        guard #available(macOS 26, *), let item = manager.addLocalFiles([clip]).first else {
            return check("gyai2: flow needs macOS 26", true)
        }
        let spoken = (0..<24).map { i in Transcript.Word(s: Double(i) * 0.5, e: Double(i) * 0.5 + 0.4, t: i == 4 ? " wrld" : " word\(i)") }
        let saved = Transcript(id: item.transcriptID ?? UUID().uuidString, title: item.title, filePath: clip.path, language: "en-US",
                               duration: 12, created: .now, words: spoken)
        item.transcriptID = saved.id
        TranscriptStore.save(saved.correctingWords(4...4, to: "world"))
        let read = try? await AppDelegate.shared?.ai.existingOrNewTranscript(for: item, file: clip)
        check("gyai2: corrected word read back by the tools", read?.words[4].t == " world", read.map { "\($0.words.prefix(6).map(\.t))" } ?? "none")
        if let read {
            let ass = folder.appendingPathComponent("c.ass")
            try? Shorts.captionFile(for: Shorts.Moment(start: 0, end: 6, title: "x"), transcript: read, design: CaptionDesign(), cuts: [], to: ass)
            let text = (try? String(contentsOf: ass, encoding: .utf8)) ?? ""
            check("gyai2: short's captions burn the corrected word", text.localizedCaseInsensitiveContains("world") && !text.localizedCaseInsensitiveContains("wrld"))
        }
        if let ai = AppDelegate.shared?.ai {
            var make = Shorts.Options()
            make.captions = nil
            make.framing = .whole
            ai.makeShorts(item, options: make, reviewed: [Shorts.Moment(start: 2, end: 7, title: "Reviewed")])
            for _ in 0..<120 where item.aiStatus != nil { try? await Task.sleep(for: .seconds(1)) }
            let shorts = folder.appendingPathComponent("clip" + String(localized: " (shorts)"))
            let made = (try? FileManager.default.contentsOfDirectory(at: shorts, includingPropertiesForKeys: nil)) ?? []
            var length = 0.0
            if let first = made.first { length = (try? await AVURLAsset(url: first).load(.duration).seconds) ?? 0 }
            check("gyai2: the reviewed moment is the short made", made.count == 1 && made[0].lastPathComponent.contains("Reviewed")
                  && abs(length - 5) < 0.3, "\(made.map(\.lastPathComponent)) \(length) s")
        }
    }

    /// Brightness (0…1) of one pixel (origin bottom left).
    private static func brightness(_ image: CIImage, at point: CGPoint) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255
    }
}
