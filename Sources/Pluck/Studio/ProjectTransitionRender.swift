import AVFoundation
import CoreImage

/// The export's transitions that ffmpeg can't draw itself: for each such cut, ffmpeg writes the
/// frames either side of it (the same picture chains as the export), `ProjectTransitions.blend`
/// mixes them as the viewer does, and the export puts those frames in at the cut.
enum ProjectTransitionRender {
    /// One cut's frames to write: the cut into clip `into`, the outgoing frames to `a`, the incoming to `b`.
    struct Taps {
        var into: Int
        var a: URL
        var b: URL
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Every cut of the project that `blend` draws, rendered to a file each (by the clip it goes
    /// into). Nil when one couldn't be made (stopped, or ffmpeg failed: `problem` says why).
    static func render(_ project: Project, streams: [String: Set<String>], lengths: [String: Double], settings: EditorRenderSettings,
                       size: CGSize, fps: Double, ffmpeg: String, folder: URL, keyed: [UUID: URL] = [:]) async -> (files: [Int: URL], problem: String?) {
        let clips = project.clips
        let overlap = ProjectModel.dissolveOverlaps(clips, lengths: lengths)
        var files: [Int: URL] = [:]
        for index in clips.indices.dropFirst() where overlap[index] > 0 {
            guard let transition = clips[index].transitionIn, ProjectTransitions.native(transition) == nil else { continue }
            guard !Task.isCancelled else { return (files, nil) }
            let taps = Taps(into: index, a: folder.appendingPathComponent("a\(index).mov"), b: folder.appendingPathComponent("b\(index).mov"))
            let arguments = ProjectExports.arguments(project, streams: streams, lengths: lengths, settings: settings, audioOnly: false, size: size,
                                                     fps: fps, titles: nil, subtitles: nil, hardware: false, output: taps.a, taps: taps, keyed: keyed)
            let outcome = await EditorExport.run(ffmpeg, arguments, total: overlap[index] * 2, progress: { _ in })
            if case .failed(let tail) = outcome, await ScreenshotMode.scene != nil {
                // Tests: the command, to run by hand.
                try? ([ffmpeg] + arguments + ["", tail]).joined(separator: "\n")
                    .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pluck-transition-taps.txt"), atomically: true, encoding: .utf8)
            }
            guard outcome.isDone else { return (files, outcome.isFailed ? EditorExport.readable(outcome) ?? String(localized: "A transition couldn’t be drawn.") : nil) }
            let out = folder.appendingPathComponent("t\(index).mov")
            let frames = Int((overlap[index] * 2 * fps).rounded())
            guard await blend(taps.a, taps.b, to: out, transition, frames: frames, size: size, fps: fps) else {
                return (files, String(localized: "A transition couldn’t be drawn."))
            }
            try? FileManager.default.removeItem(at: taps.a)
            try? FileManager.default.removeItem(at: taps.b)
            files[index] = out
        }
        return (files, nil)
    }

    /// The frames of `a` into those of `b` (`frames` of them, frame i at i / frames of the way), drawn
    /// as the viewer draws them and written as ProRes.
    // shortcut: 8 bits a channel, as the viewer; upgrade to 64RGBAHalf if 10-bit exports show banding in transitions.
    static func blend(_ a: URL, _ b: URL, to out: URL, _ transition: ProjectTransition, frames: Int, size: CGSize, fps: Double) async -> Bool {
        let format: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        func reader(_ url: URL) async -> (AVAssetReader, AVAssetReaderTrackOutput)? {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: format)
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            return reader.startReading() ? (reader, output) : nil
        }
        guard let (ra, oa) = await reader(a), let (rb, ob) = await reader(b) else { return false }
        defer { ra.cancelReading(); rb.cancelReading() }
        try? FileManager.default.removeItem(at: out)
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: format.merging([
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ]) { $1 })
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let rect = CGRect(origin: .zero, size: size)
        var made = 0
        while made < frames, !Task.isCancelled {
            guard let fa = oa.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer),
                  let fb = ob.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer) else { break }
            // As the viewer takes a frame: the file's picture in its colour.
            let picture = ProjectTransitions.blend(transition, from: fitted(CIImage(cvPixelBuffer: fa), rect), to: fitted(CIImage(cvPixelBuffer: fb), rect),
                                                   progress: Double(made) / Double(max(frames, 1)), size: size)
            while !input.isReadyForMoreMediaData, writer.status == .writing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            guard writer.status == .writing else { break }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            context.render(picture, to: buffer, bounds: rect, colorSpace: ProjectCompositor.video)
            let time = CMTime(value: CMTimeValue(made) * 1000, timescale: CMTimeScale((fps * 1000).rounded()))
            guard adaptor.append(buffer, withPresentationTime: time) else { break }
            made += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed && made > 0 && !Task.isCancelled
    }

    /// The frame at the export's size (ffmpeg made it so; this only guards against a pixel's rounding).
    private static func fitted(_ image: CIImage, _ rect: CGRect) -> CIImage {
        guard image.extent.size != rect.size, image.extent.width > 0, image.extent.height > 0 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: rect.width / image.extent.width, y: rect.height / image.extent.height))
    }
}
