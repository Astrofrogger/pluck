import AVFoundation
import CoreImage

/// The export's keyframed clips: ffmpeg writes each one's own frames (trimmed, at its speed, its
/// camera's log made normal), `ClipLook.place` puts every frame where its keyframes say, as the
/// viewer does, and the export takes those frames in place of the clip's picture chain. Clips
/// without picture keyframes stay on ffmpeg's own (faster) chain.
enum ProjectKeyframeRender {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A main-line clip or track item with picture keyframes.
    static func isKeyed(_ clip: ProjectClip) -> Bool {
        clip.look?.keyedProperties.contains { $0.path != nil } == true
    }

    /// Every keyframed clip and picture item, drawn to a file each (by its id). Nil-free: a clip
    /// that couldn't be drawn stops the export (`problem` says why).
    static func render(_ project: Project, streams: [String: Set<String>], lengths: [String: Double], size: CGSize, fps: Double,
                       ffmpeg: String, folder: URL) async -> (files: [UUID: URL], problem: String?) {
        var files: [UUID: URL] = [:]
        let clips = project.clips
        let overlap = ProjectModel.dissolveOverlaps(clips, lengths: lengths)
        var jobs: [(clip: ProjectClip, before: Double, after: Double, main: Bool)] = []
        for (k, clip) in clips.enumerated() where isKeyed(clip) && streams[clip.path]?.contains("video") == true {
            jobs.append((clip, overlap[k], k + 1 < clips.count ? overlap[k + 1] : 0, true))
        }
        for track in project.tracks ?? [] where track.kind == .video && !track.hidden {
            for item in track.items where isKeyed(item) && streams[item.path]?.contains("video") == true { jobs.append((item, 0, 0, false)) }
        }
        for job in jobs {
            guard !Task.isCancelled else { return (files, nil) }
            let source = folder.appendingPathComponent("k-\(job.clip.id.uuidString)-src.mov")
            let out = folder.appendingPathComponent("k-\(job.clip.id.uuidString).mov")
            let length = job.clip.length + job.before + job.after
            let arguments = sourceArguments(job.clip, before: job.before, after: job.after, fps: fps, output: source)
            let outcome = await EditorExport.run(ffmpeg, arguments, total: length, progress: { _ in })
            guard outcome.isDone else {
                return (files, outcome.isFailed ? EditorExport.readable(outcome) ?? String(localized: "A keyframed clip couldn’t be drawn.") : nil)
            }
            let frames = max(Int((length * fps).rounded()), 1)
            guard await place(source, to: out, clip: job.clip, before: job.before, frames: frames, size: size, fps: fps, main: job.main) else {
                return (files, Task.isCancelled ? nil : String(localized: "A keyframed clip couldn’t be drawn."))
            }
            try? FileManager.default.removeItem(at: source)
            files[job.clip.id] = out
        }
        return (files, nil)
    }

    /// ffmpeg's command for a clip's own frames (with a dissolve's extra frames either side), as ProRes 4444.
    static func sourceArguments(_ clip: ProjectClip, before: Double, after: Double, fps: Double, output: URL) -> [String] {
        func number(_ value: Double) -> String { String(format: "%.4f", value) }
        let look = clip.look ?? ClipLook()
        let copy = look.stabilize ? Stabilizer.copy(for: clip.path)?.path : nil
        let length = clip.length + before + after
        let from: Double, steps: [String]
        if let freeze = clip.freeze {
            from = freeze
            steps = ClipLook.ffmpegSourceSteps(start: 0, end: 1, look: look, steadied: copy != nil, hold: length, path: clip.path)
        } else {
            let start = clip.start - before * clip.speed, end = clip.end + after * clip.speed
            from = max(start, 0)
            steps = ClipLook.ffmpegSourceSteps(start: start - from, end: end - from, look: look, steadied: copy != nil, path: clip.path)
        }
        var inputs: [String] = []
        if from > 0 { inputs += ["-ss", number(from)] }
        inputs += ["-t", number((clip.freeze != nil ? 1 : length * clip.speed) + 1), "-i", copy ?? clip.path]
        let chain = "[0:v:0]" + (steps + ["fps=\(EditorRenderSettings.rate(fps))", "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"])
            .joined(separator: ",") + "[v]"
        return ["-nostdin", "-y", "-v", "error", "-progress", "pipe:1"] + inputs + ["-filter_complex", chain, "-map", "[v]",
                "-c:v", "prores_ks", "-profile:v", "4", "-pix_fmt", "yuva444p10le", "-color_primaries", "bt709", "-color_trc", "bt709",
                "-colorspace", "bt709", "-an", output.path]
    }

    /// Each frame of `source` placed by the clip's look at its moment (frame i is i / fps into the
    /// file, `before` seconds ahead of the clip's start), written as ProRes (with alpha for an item).
    // shortcut: 8 bits a channel, as the viewer and the transitions; upgrade with them if 10-bit exports band.
    static func place(_ source: URL, to out: URL, clip: ProjectClip, before: Double, frames: Int, size: CGSize, fps: Double, main: Bool) async -> Bool {
        let format: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        defer { reader.cancelReading() }
        try? FileManager.default.removeItem(at: out)
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: main ? AVVideoCodecType.proRes422HQ : AVVideoCodecType.proRes4444,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
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
        let look = clip.look ?? ClipLook()
        var made = 0
        var last: CIImage?
        while made < frames, !Task.isCancelled {
            // The file ends a frame early (rounding): its last frame again.
            if let buffer = output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer) { last = CIImage(cvPixelBuffer: buffer) }
            guard let frame = last else { break }
            let at = Double(made) / fps - before
            let progress = min(max(at / max(clip.length, 0.001), 0), 1)
            var picture = ClipLook.place(frame, look: look.resolved(at: at), progress: progress, in: size, onBlack: main)
            // ProRes keeps its alpha straight.
            if !main { picture = picture.unpremultiplyingAlpha() }
            while !input.isReadyForMoreMediaData, writer.status == .writing, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool else { break }
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
        return writer.status == .completed && made == frames && !Task.isCancelled
    }
}
