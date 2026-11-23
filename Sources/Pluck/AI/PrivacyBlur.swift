import AppKit
import AVFoundation
import CoreImage
import Vision

/// Privacy Blur: finds faces (and optionally text, like licence plates and name tags) with Apple's
/// Vision (local AI), follows each face through the video, and blurs everyone except the people
/// the user keeps sharp.
enum PrivacyBlur {
    enum Style: String, CaseIterable, Identifiable {
        case blur, pixelate
        var id: String { rawValue }

        var label: String {
            switch self {
            case .blur: String(localized: "Blur")
            case .pixelate: String(localized: "Pixelate")
            }
        }
    }

    /// One face followed through the video. Boxes are 0…1 of the upright picture, origin bottom left.
    struct Track: Identifiable, @unchecked Sendable {
        let id: Int
        var samples: [(time: Double, box: CGRect)]
        /// The clearest look at this face, for choosing who stays sharp.
        var thumbnail: CGImage?
        var thumbnailArea: CGFloat = 0
        /// Drawn by the user (then followed from there): covered as drawn, not as a face.
        var manual = false

        var start: Double { samples.first?.time ?? 0 }
        var end: Double { samples.last?.time ?? 0 }

        /// Where the face is at a moment: between two looks it glides; just before the first
        /// and after the last look it stays put, so a face is covered as it appears and leaves.
        func box(at time: Double, hold: Double) -> CGRect? {
            guard let first = samples.first, let last = samples.last,
                  time >= first.time - hold, time <= last.time + hold else { return nil }
            if time <= first.time { return first.box }
            if time >= last.time { return last.box }
            guard let after = samples.firstIndex(where: { $0.time >= time }), after > 0 else { return first.box }
            let a = samples[after - 1], b = samples[after]
            // A long gap means the face was gone (or hidden) in between.
            guard b.time - a.time < 1.2 else { return time - a.time < hold ? a.box : (b.time - time < hold ? b.box : nil) }
            let f = (time - a.time) / max(b.time - a.time, 0.001)
            return CGRect(x: a.box.minX + (b.box.minX - a.box.minX) * f, y: a.box.minY + (b.box.minY - a.box.minY) * f,
                          width: a.box.width + (b.box.width - a.box.width) * f, height: a.box.height + (b.box.height - a.box.height) * f)
        }
    }

    final class Analysis: @unchecked Sendable {
        var faces: [Track] = []
        /// Text seen at each look (boxes as above).
        var text: [(time: Double, boxes: [CGRect])] = []
        /// Seconds between looks.
        var step = 0.125
    }

    /// Looks through the video about eight times a second.
    static func analyze(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Analysis {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw FrameRewriter.Failure.noVideo }
        let (natural, transform, range) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        // Faces are found fine at this size, and it's much faster than full resolution.
        let scale = min(1, 960 / max(natural.width, natural.height))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int((natural.width * scale / 2).rounded() * 2),
            kCVPixelBufferHeightKey as String: Int((natural.height * scale / 2).rounded() * 2),
        ])
        reader.add(output)
        guard reader.startReading() else { throw FrameRewriter.Failure.writing(reader.error?.localizedDescription ?? "") }

        let analysis = Analysis()
        let orientation = FrameRewriter.orientation(of: transform)
        let context = CIContext()
        let total = max(range.duration.seconds, 0.1)
        var nextLook = 0.0
        var nextID = 1
        while let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            try Task.checkCancellation()
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds - range.start.seconds
            guard seconds >= nextLook else { continue }
            nextLook = seconds + analysis.step
            var image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

            let faces = VNDetectFaceRectanglesRequest()
            let text = VNDetectTextRectanglesRequest()
            try VNImageRequestHandler(ciImage: image).perform([faces, text])
            analysis.text.append((seconds, (text.results ?? []).map(\.boundingBox)))

            for face in faces.results ?? [] {
                let box = face.boundingBox
                // The same face as one seen a moment ago: close by and about the same size.
                let match = analysis.faces.indices.filter { index in
                    guard let last = analysis.faces[index].samples.last, seconds - last.time < 1.2 else { return false }
                    let distance = hypot(last.box.midX - box.midX, last.box.midY - box.midY)
                    let size = max(last.box.width, box.width)
                    return distance < size * 0.9 && abs(last.box.width - box.width) < size * 0.6
                }.min { a, b in
                    let la = analysis.faces[a].samples.last!.box, lb = analysis.faces[b].samples.last!.box
                    return hypot(la.midX - box.midX, la.midY - box.midY) < hypot(lb.midX - box.midX, lb.midY - box.midY)
                }
                let index: Int
                if let match, analysis.faces[match].samples.last!.time < seconds {
                    analysis.faces[match].samples.append((seconds, box))
                    index = match
                } else {
                    analysis.faces.append(Track(id: nextID, samples: [(seconds, box)]))
                    nextID += 1
                    index = analysis.faces.count - 1
                }
                // Keep the biggest, clearest look as the thumbnail.
                let area = box.width * box.height
                if area > analysis.faces[index].thumbnailArea {
                    analysis.faces[index].thumbnailArea = area
                    let rect = expanded(box, by: 0.5, in: image.extent)
                    analysis.faces[index].thumbnail = context.createCGImage(image, from: rect)
                }
            }
            progress(min(seconds / total, 1))
        }
        // Single glimpses are sometimes not faces at all, but blurring them anyway is the safe side.
        analysis.faces.sort { $0.start < $1.start }
        return analysis
    }

    /// A box in picture coordinates, made bigger around its centre (faces are found tight,
    /// without hair and ears).
    static func expanded(_ box: CGRect, by amount: CGFloat, in extent: CGRect) -> CGRect {
        let w = box.width * extent.width, h = box.height * extent.height
        let rect = CGRect(x: box.minX * extent.width - w * amount / 2, y: box.minY * extent.height - h * amount / 2,
                          width: w * (1 + amount), height: h * (1 + amount))
        return rect.intersection(extent)
    }

    /// A region the user drew at `time` (a box as above), followed forwards and backwards with
    /// Vision's object tracker, a look every `step`, until it's lost (a cut, gone from view).
    /// shortcut: at most a minute each way from where it was drawn; draw again further on if longer.
    static func follow(_ file: URL, box: CGRect, at time: Double, step: Double, id: Int) async -> Track {
        let asset = AVURLAsset(url: file)
        let duration = (try? await asset.load(.duration).seconds) ?? time
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: step / 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 4, preferredTimescale: 600)
        var track = Track(id: id, samples: [(time, box)], manual: true)
        if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
            let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let rect = expanded(box, by: 0.3, in: extent)
            // CGImage cropping counts from the top.
            track.thumbnail = image.cropping(to: CGRect(x: rect.minX, y: extent.height - rect.maxY, width: rect.width, height: rect.height))
        }
        for direction in [1.0, -1.0] {
            var observation = VNDetectedObjectObservation(boundingBox: box)
            let sequence = VNSequenceRequestHandler()
            var t = time + step * direction
            while t >= 0, t <= duration, abs(t - time) <= 60, !Task.isCancelled {
                guard let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { break }
                let request = VNTrackObjectRequest(detectedObjectObservation: observation)
                request.trackingLevel = .accurate
                guard (try? sequence.perform([request], on: image)) != nil,
                      let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.3 else { break }
                observation = result
                track.samples.append((t, result.boundingBox))
                t += step * direction
            }
        }
        track.samples.sort { $0.time < $1.time }
        return track
    }

    /// The step that blurs one frame.
    final class Painter: @unchecked Sendable {
        let faces: [Track]
        let text: [(time: Double, boxes: [CGRect])]
        let step: Double
        let style: Style

        init(analysis: Analysis, keepSharp: Set<Int>, blurText: Bool, style: Style) {
            faces = analysis.faces.filter { !keepSharp.contains($0.id) }
            text = blurText ? analysis.text : []
            step = analysis.step
            self.style = style
        }

        func paint(_ frame: CIImage, at seconds: Double) -> CIImage {
            let extent = frame.extent
            guard let mask = mask(extent, at: seconds) else { return frame }
            let hidden: CIImage = switch style {
            case .blur: frame.clampedToExtent().applyingGaussianBlur(sigma: extent.height / 45).cropped(to: extent)
            case .pixelate: frame.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(extent.height / 40, 8)]).cropped(to: extent)
            }
            return hidden.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: mask])
        }

        /// What's hidden at a moment: white on black (the matte for Resolve), nil when nothing is.
        func mask(_ extent: CGRect, at seconds: Double) -> CIImage? {
            var mask = CIImage(color: .black).cropped(to: extent)
            var any = false
            for face in faces {
                guard let box = face.box(at: seconds, hold: face.manual ? step : 0.4) else { continue }
                if face.manual {
                    let patch = CIImage(color: .white).cropped(to: PrivacyBlur.expanded(box, by: 0.1, in: extent))
                    mask = patch.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                    any = true
                    continue
                }
                // A soft oval over the face, hair and ears.
                let rect = PrivacyBlur.expanded(box, by: 0.7, in: extent)
                let radius = max(rect.width, rect.height) / 2
                let spot = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: 0, y: 0), "inputRadius0": radius * 0.75, "inputRadius1": radius,
                    "inputColor0": CIColor.white, "inputColor1": CIColor.clear,
                ])!.outputImage!
                let shaped = spot.transformed(by: CGAffineTransform(scaleX: rect.width / (radius * 2), y: rect.height / (radius * 2)))
                    .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
                    .cropped(to: rect)
                mask = shaped.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                any = true
            }
            if let look = text.last(where: { $0.time <= seconds + 0.01 }), seconds - look.time <= step * 2 {
                for box in look.boxes {
                    let rect = PrivacyBlur.expanded(box, by: 0.25, in: extent)
                    let patch = CIImage(color: .white).cropped(to: rect)
                    mask = patch.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                    any = true
                }
            }
            return any ? mask : nil
        }
    }
}

extension AIStudio {
    /// Makes a "(blurred)" copy next to the video.
    func privacyBlur(_ item: DownloadItem, analysis: PrivacyBlur.Analysis, keepSharp: Set<Int>, blurText: Bool, style: PrivacyBlur.Style) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Blurring…")
            item.aiProgress = 0
            let picture = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-blur-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: picture) }
            do {
                let painter = PrivacyBlur.Painter(analysis: analysis, keepSharp: keepSharp, blurText: blurText, style: style)
                try await Self.offMain {
                    try await FrameRewriter().run(input: file, output: picture, codec: .hevc) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    } edit: { frame in
                        painter.paint(frame.image, at: frame.seconds)
                    }
                }
                item.aiStatus = String(localized: "Saving…")
                item.aiProgress = nil
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (blurred)"),
                                                  fileExtension: file.pathExtension.lowercased() == "mov" ? "mov" : "mp4")
                let source = await FrameRewriter.keepingSource(file, input: 1, ffprobe: toolPath("ffprobe"))
                try await ffmpeg(["-y", "-v", "error", "-i", picture.path, "-i", file.path, "-map", "0:v", "-map", "1:a?"] + source + [
                                  "-c:v", "copy", "-c:a", "copy", "-shortest", "-tag:v", "hvc1", "-movflags", "+faststart", output.path],
                                 failure: FrameRewriter.Failure.noVideo)
                finishJob(item)
                notify(title: String(localized: "“\(item.title)” is blurred"),
                       body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }
}

extension AIStudio {
    /// A "(matte)" .mov next to the video: white where Privacy Blur hides something, black
    /// elsewhere (ProRes 4444), to finish the blur in DaVinci Resolve as an external matte.
    func privacyMatte(_ item: DownloadItem, analysis: PrivacyBlur.Analysis, keepSharp: Set<Int>, blurText: Bool) {
        guard let file = item.existingFile else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Making the matte…")
            item.aiProgress = 0
            do {
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (matte)"),
                                                  fileExtension: "mov")
                try await Self.writeMatte(file, to: output, analysis: analysis, keepSharp: keepSharp, blurText: blurText) { progress in
                    Task { @MainActor in item.aiProgress = progress }
                }
                finishJob(item)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }

    /// The matte itself (no sound), the source's tags kept so it lines up in Resolve.
    nonisolated static func writeMatte(_ file: URL, to output: URL, analysis: PrivacyBlur.Analysis, keepSharp: Set<Int>, blurText: Bool,
                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let painter = PrivacyBlur.Painter(analysis: analysis, keepSharp: keepSharp, blurText: blurText, style: .blur)
        let picture = output.deletingLastPathComponent().appendingPathComponent(".pluck-matte-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: picture) }
        try await offMain {
            try await FrameRewriter().run(input: file, output: picture, codec: .proRes4444, progress: progress) { frame in
                painter.mask(frame.image.extent, at: frame.seconds) ?? CIImage(color: .black).cropped(to: frame.image.extent)
            }
        }
        let (ffmpeg, ffprobe) = await MainActor.run { (AppDelegate.shared?.manager.tool("ffmpeg"), AppDelegate.shared?.manager.tool("ffprobe")) }
        guard let ffmpeg else {
            try FileManager.default.moveItem(at: picture, to: output)
            return
        }
        // The start timecode and reel name (container or timecode track), so the matte lines up with the clip.
        let source = await FrameRewriter.keepingSource(file, input: 1, ffprobe: ffprobe)
        let outcome = await EditorExport.run(ffmpeg, ["-y", "-v", "error", "-i", picture.path, "-i", file.path, "-map", "0:v"]
                                                      + source + ["-c", "copy", EditorExport.partial(output).path], total: 0) { _ in }
        guard case .done = outcome else {
            try? FileManager.default.removeItem(at: EditorExport.partial(output))
            try FileManager.default.moveItem(at: picture, to: output)
            return
        }
        try FileManager.default.moveItem(at: EditorExport.partial(output), to: output)
    }
}
