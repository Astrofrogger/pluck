import AVFoundation
import AppKit

/// Social Cutdowns (-PluckScreenshotOnly cutdowns): a made 16:9 clip, a textured box moving across the first shot and
/// standing still in the second, with a text box near the left edge. The crop follows the box closely and smoothly,
/// holds in the still shot, the text is kept in or flagged, a picked subject is tracked, and the three renders have
/// the right size, length and frame rate, with captions burned in when asked.
extension PhotoSelfTest {
    static func cutdownsTest() async {
        guard let manager = AppDelegate.shared?.manager, let ffmpeg = manager.tool("ffmpeg") else {
            return check("cutdowns: ffmpeg", false, "no ffmpeg")
        }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("CutdownsTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // The text, drawn here (ffmpeg's drawtext may be missing).
        let textPNG = folder.appendingPathComponent("text.png")
        let label = NSAttributedString(string: "SAMPLE TEXT", attributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.white])
        let textSize = CGSize(width: ceil(label.size().width) + 16, height: 52)
        if let context = CGContext(data: nil, width: Int(textSize.width), height: Int(textSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            label.draw(at: CGPoint(x: 8, y: 8))
            NSGraphicsContext.restoreGraphicsState()
            if let image = context.makeImage(), let out = CGImageDestinationCreateWithURL(textPNG as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(out, image, nil)
                CGImageDestinationFinalize(out)
            }
        }
        let W = 1280.0, H = 720.0, boxW = 120.0, boxH = 160.0
        let truth = { (t: Double) -> Double in t < 4 ? 0.25 + 0.5 * (1 - cos(Double.pi * t / 4)) / 2 : 0.6 }
        let clip = folder.appendingPathComponent("edit.mp4")
        let graph = "[0][2]overlay=x='\(W)*(0.25+0.25*(1-cos(PI*t/4)))-\(boxW / 2)':y=\((H - boxH) / 2):shortest=1[s1];"
            + "[1][2]overlay=x=\(W * 0.6 - boxW / 2):y=\((H - boxH) / 2):shortest=1[s2];[s1][s2]concat=n=2:v=1:a=0[both];"
            + "[both][3]overlay=x=\(Int(W * 0.03)):y=\(Int(H * 0.45))[v]"
        _ = await DeliveryCheck.output(ffmpeg, ["-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=0x202020:s=1280x720:r=25:d=4", "-f", "lavfi", "-i", "color=c=0x305080:s=1280x720:r=25:d=2",
            "-f", "lavfi", "-i", "testsrc2=s=\(Int(boxW))x\(Int(boxH)):r=25:d=6", "-loop", "1", "-i", textPNG.path,
            "-f", "lavfi", "-i", "sine=f=440:r=48000:d=6",
            "-filter_complex", graph, "-map", "[v]", "-map", "4", "-t", "6",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", clip.path])
        guard FileManager.default.fileExists(atPath: clip.path) else { return check("cutdowns: test clip made", false, "ffmpeg failed") }

        guard let analysis = try? await SocialCutdowns.analyse(clip, ffmpeg: ffmpeg, brand: nil, progress: { _ in }) else {
            return check("cutdowns: analysed", false, "no analysis")
        }
        check("cutdowns: two shots, cut at 4 s", analysis.shots.count == 2 && abs((analysis.shots.last?.start ?? 0) - 4) < 0.25,
              analysis.shots.map { String(format: "%.2f–%.2f", $0.start, $0.end) }.joined(separator: ", "))
        let found = analysis.samples.filter { $0.subject != nil && $0.time < 4 }.map { abs(Double($0.subject!.midX) - truth($0.time)) }
        check("cutdowns: subject seen", found.count > 10 && (found.max() ?? 1) < 0.05,
              "\(found.count) samples, worst \(found.max() ?? -1)")
        check("cutdowns: text found", analysis.shots.first.map { $0.graphics.contains { $0.minX < 0.1 && $0.midY > 0.4 && $0.midY < 0.6 } } ?? false,
              "\(analysis.shots.first?.graphics ?? [])")

        let plans = SocialCutdowns.plan(analysis, format: .vertical, edits: [:])
        let f = SocialCutdowns.cropFraction(width: 1280, height: 720, format: .vertical)
        let frameTimes = (0..<150).map { Double($0) / 25 }
        let centres = frameTimes.map { t in SocialCutdowns.centre(plans, at: t)?.centre(at: t) ?? 0.5 }
        let errors = zip(frameTimes, centres).filter { $0.0 > 0.2 && $0.0 < 3.8 }.map { abs($0.1 - truth($0.0)) }
        let meanError = errors.reduce(0, +) / Double(max(errors.count, 1))
        check("cutdowns: crop follows the subject", meanError < 0.04 && (errors.max() ?? 1) < f / 2 - boxW / W / 2,
              String(format: "mean %.4f, worst %.4f", meanError, errors.max() ?? -1))
        let jumps = zip(frameTimes.dropFirst(), zip(centres, centres.dropFirst())).filter { abs($0.0 - 4) > 0.3 }.map { abs($0.1.1 - $0.1.0) }
        check("cutdowns: path is smooth", (jumps.max() ?? 1) < 0.012, String(format: "biggest jump %.4f a frame", jumps.max() ?? -1))
        let still = zip(frameTimes, centres).filter { $0.0 > 4.2 }.map(\.1)
        check("cutdowns: holds on a still subject", (still.max() ?? 1) - (still.min() ?? 0) < 0.002 && abs((still.first ?? 0) - 0.6) < 0.03,
              "\(still.min() ?? -1)…\(still.max() ?? -1)")
        // The text is kept inside the crop's safe area, or the shot says it isn't.
        let safe = SocialCutdowns.safeArea(.vertical)
        if let shot = analysis.shots.first, let text = shot.graphics.first, let plan = plans.first {
            let inside = zip(frameTimes, centres).filter { $0.0 < shot.end }.allSatisfy { _, c in
                let left = c - f / 2 + f * Double(safe.minX), right = c - f / 2 + f * Double(safe.maxX)
                return Double(text.minX) >= left && Double(text.maxX) <= right
            }
            check("cutdowns: text kept in or flagged", inside || plan.flagged, "inside \(inside), flagged \(plan.flagged)")
            check("cutdowns: still shot not flagged", plans.count < 2 || !plans[1].flagged || plans[1].framing == .follow, "")
        }
        // Square: the text fits next to the box only sometimes; the same rule holds.
        let square = SocialCutdowns.plan(analysis, format: .square, edits: [:])
        check("cutdowns: square planned", square.count == analysis.shots.count, "")

        // A subject picked by hand, tracked through the shot.
        if let shot = analysis.shots.first, let path = await SocialCutdowns.track(analysis, shot: shot, time: 2, point: CGPoint(x: 0.5, y: 0.5)) {
            let samples = analysis.samples(in: shot)
            let trackErrors = zip(samples, path).map { abs($0.1 - truth($0.0.time)) }
            check("cutdowns: picked subject tracked", (trackErrors.max() ?? 1) < 0.06,
                  String(format: "worst %.4f; ", trackErrors.max() ?? -1) + path.map { String(format: "%.2f", $0) }.joined(separator: " "))
        } else {
            check("cutdowns: picked subject tracked", false, "no path")
        }
        // A crop dragged into place holds there.
        var edits: [Double: SocialCutdowns.ShotEdit] = [:]
        edits[analysis.shots[0].start] = SocialCutdowns.ShotEdit(locks: [.vertical: 0.3], framing: [.square: .blur])
        let locked = SocialCutdowns.plan(analysis, format: .vertical, edits: edits)
        check("cutdowns: lock holds", locked[0].locked && locked[0].centres.allSatisfy { abs($0 - 0.3) < 1e-9 }, "")
        check("cutdowns: framing override", SocialCutdowns.plan(analysis, format: .square, edits: edits)[0].framing == .blur, "")

        // Renders.
        let cue = Transcript.Cue(start: 1, end: 5, text: "HELLO WORLD", words: 0..<0)
        func render(_ format: SocialCutdowns.Format, captions: Bool, edits: [Double: SocialCutdowns.ShotEdit] = [:]) async -> URL? {
            let job = SocialCutdowns.Render(format: format, plans: SocialCutdowns.plan(analysis, format: format, edits: edits),
                                            cues: captions ? [cue] : nil, design: CaptionDesign(), logo: nil, folder: folder)
            do { return try await SocialCutdowns.render(analysis, job, ffmpeg: ffmpeg, progress: { _ in }) } catch {
                check("cutdowns: \(format.tag) rendered", false, error.localizedDescription)
                return nil
            }
        }
        var captionedVertical: URL?
        for format in SocialCutdowns.formats {
            guard let url = await render(format, captions: true, edits: format == .square ? edits : [:]) else { continue }
            if format == .vertical { captionedVertical = url }
            let asset = AVURLAsset(url: url)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let size = (try? await track?.load(.naturalSize)) ?? .zero
            let rate = (try? await track?.load(.nominalFrameRate)) ?? 0
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            let audio = (try? await asset.loadTracks(withMediaType: .audio).count) ?? 0
            check("cutdowns: \(format.tag) size, length, rate, sound",
                  Int(size.width) == format.size.width && Int(size.height) == format.size.height && abs(duration - 6) < 0.15 && abs(rate - 25) < 0.1 && audio == 1,
                  "\(size) \(duration) s \(rate) fps \(audio) audio")
        }
        // Captions: the same frame with and without.
        if let plain = await render(.vertical, captions: false), let captioned = captionedVertical {
            func frame(_ url: URL) async -> [UInt8] {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                guard let image = try? await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600)).image else { return [] }
                let w = 270, h = 480
                var bytes = [UInt8](repeating: 0, count: w * h)
                bytes.withUnsafeMutableBytes { buffer in
                    CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?
                        .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                return bytes
            }
            let a = await frame(plain), b = await frame(captioned)
            let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > 40 }.count
            check("cutdowns: captions burned in", !a.isEmpty && a.count == b.count && Double(changed) / Double(a.count) > 0.002,
                  "\(changed) of \(a.count) pixels changed")
        } else {
            check("cutdowns: captions burned in", false, "renders missing")
        }
    }
}
