import AppKit
import AVFoundation
import CoreImage
import VideoToolbox

/// Upscale & Smooth: Apple's on-device video processing (local AI, macOS 26) makes low-resolution
/// video sharper (super resolution) and adds frames in between the existing ones (frame rate
/// conversion), for smoother motion or slow motion.
enum Enhance {
    enum Upscale: String, CaseIterable, Identifiable {
        case off, hd, uhd
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: String(localized: "Keep size")
            case .hd: String(localized: "1080p")
            case .uhd: String(localized: "4K")
            }
        }

        var height: Int? {
            switch self {
            case .off: nil
            case .hd: 1080
            case .uhd: 2160
            }
        }
    }

    enum Motion: String, CaseIterable, Identifiable {
        case off, smooth, slow2, slow4
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: String(localized: "Keep as is")
            case .smooth: String(localized: "Twice as smooth")
            case .slow2: String(localized: "Slow motion 2×")
            case .slow4: String(localized: "Slow motion 4×")
            }
        }

        /// New frames made between each pair of original frames.
        var inBetween: Int {
            switch self {
            case .off: 0
            case .smooth, .slow2: 1
            case .slow4: 3
            }
        }

        /// How much longer the video gets.
        var stretch: Double {
            switch self {
            case .off, .smooth: 1
            case .slow2: 2
            case .slow4: 4
            }
        }
    }

    struct Options {
        var upscale: Upscale = .hd
        var motion: Motion = .off
    }

    enum Failure: LocalizedError {
        case unavailable, noVideo, nothingToDo, writing(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Upscaling and smooth motion need macOS 26 or later on a Mac with Apple silicon.")
            case .noVideo: String(localized: "Pluck couldn’t read the picture of this video.")
            case .nothingToDo: String(localized: "This video is already that size. Choose a larger size or smoother motion.")
            case .writing(let reason): reason
            }
        }
    }

    static var canUpscale: Bool {
        guard #available(macOS 26, *) else { return false }
        return VTSuperResolutionScalerConfiguration.isSupported && VTSuperResolutionScalerConfiguration.supportedScaleFactors.contains(4)
    }

    static var canSmooth: Bool {
        guard #available(macOS 26, *) else { return false }
        return VTFrameRateConversionConfiguration.isSupported
    }

    static var isSupported: Bool { canUpscale || canSmooth }

    /// Output size: the target height (never smaller than the source), same shape, even numbers.
    static func outputSize(source: CGSize, upscale: Upscale) -> CGSize {
        guard let height = upscale.height, Double(height) > source.height else { return source }
        let width = (Double(height) * source.width / source.height / 2).rounded() * 2
        return CGSize(width: width, height: Double(height))
    }
}

@available(macOS 26, *)
final class VideoEnhancer: @unchecked Sendable {
    let options: Enhance.Options
    /// No colour management: the video's values pass through untouched (they're BT.709, which
    /// Core Image would otherwise treat as sRGB and brighten), and the output is tagged BT.709.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

    init(options: Enhance.Options) {
        self.options = options
    }

    /// Writes the enhanced picture (no sound) to `output`. `progress` gets 0…1.
    func run(input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Enhance.Failure.noVideo }
        let (natural, transform, rate, duration) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        let source = CGSize(width: abs(natural.width), height: abs(natural.height))
        // Sizes are worked out on the picture as it's stored; the rotation is kept as metadata.
        let upright = natural.applying(transform)
        let target = Enhance.outputSize(source: CGSize(width: abs(upright.width), height: abs(upright.height)), upscale: options.upscale)
        let rotated = abs(upright.width) != source.width
        let outSize = rotated ? CGSize(width: target.height, height: target.width) : target
        let upscaling = outSize.width > source.width + 1
        guard upscaling || options.motion != .off else { throw Enhance.Failure.nothingToDo }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(readerOutput)

        let frameRate = Double(rate > 0 ? rate : 30)
        let outputRate = options.motion == .smooth ? frameRate * 2 : frameRate
        let pixels = outSize.width * outSize.height
        let bitrate = Int(min(max(pixels * outputRate * 0.12, 6_000_000), 80_000_000))
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(outSize.width), AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: Int(outputRate.rounded())],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outSize.width), kCVPixelBufferHeightKey as String: Int(outSize.height),
        ])
        writer.add(writerInput)

        let width = Int(source.width), height = Int(source.height)
        var interpolator: VTFrameProcessor?
        if options.motion != .off {
            guard let config = VTFrameRateConversionConfiguration(frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                                                                   qualityPrioritization: .quality, revision: VTFrameRateConversionConfiguration.defaultRevision)
            else { throw Enhance.Failure.unavailable }
            let processor = VTFrameProcessor()
            try processor.startSession(configuration: config)
            interpolator = processor
        }
        defer { interpolator?.endSession() }
        var scaler: VTFrameProcessor?
        if upscaling {
            guard let config = VTSuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: 4, inputType: .video,
                                                                     usePrecomputedFlow: false, qualityPrioritization: .normal,
                                                                     revision: VTSuperResolutionScalerConfiguration.defaultRevision)
            else { throw Enhance.Failure.unavailable }
            if config.configurationModelStatus != .ready {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    config.downloadConfigurationModel { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                }
            }
            let processor = VTFrameProcessor()
            try processor.startSession(configuration: config)
            scaler = processor
        }
        defer { scaler?.endSession() }

        guard reader.startReading(), writer.startWriting() else {
            throw Enhance.Failure.writing(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration.duration.seconds, 0.1)
        let stretch = options.motion.stretch
        var previousSource: VTFrameProcessorFrame?, previousScaled: VTFrameProcessorFrame?
        var pending: (frame: VTFrameProcessorFrame, time: Double)?
        var written = 0

        // One picture onward: upscale if asked, then into the file at its new time.
        func emit(_ frame: VTFrameProcessorFrame, at seconds: Double) async throws {
            var picture = CIImage(cvPixelBuffer: frame.buffer)
            if let scaler {
                let big = try makeBuffer(width * 4, height * 4, kCVPixelFormatType_64RGBAHalf)
                let destination = VTFrameProcessorFrame(buffer: big, presentationTimeStamp: frame.presentationTimeStamp)!
                guard let parameters = VTSuperResolutionScalerParameters(sourceFrame: frame, previousFrame: previousSource,
                                                                         previousOutputFrame: previousScaled, opticalFlow: nil,
                                                                         submissionMode: .sequential, destinationFrame: destination)
                else { throw Enhance.Failure.noVideo }
                _ = try await scaler.process(parameters: parameters)
                previousSource = frame
                previousScaled = destination
                makeOpaque(big)
                picture = CIImage(cvPixelBuffer: big)
            }
            let scaleX = outSize.width / picture.extent.width, scaleY = outSize.height / picture.extent.height
            if abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 {
                picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
            }
            let out = try makeBuffer(Int(outSize.width), Int(outSize.height), kCVPixelFormatType_32BGRA)
            context.render(picture, to: out)
            while !writerInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(out, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
                throw Enhance.Failure.writing(writer.error?.localizedDescription ?? "")
            }
            written += 1
        }

        while let sample = readerOutput.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = (time.seconds - duration.start.seconds) * stretch
            let half = try makeBuffer(width, height, kCVPixelFormatType_64RGBAHalf)
            context.render(CIImage(cvPixelBuffer: pixels), to: half)
            let frame = VTFrameProcessorFrame(buffer: half, presentationTimeStamp: time)!
            if let interpolator, let (previous, previousTime) = pending {
                // The earlier frame, then new ones between it and this one.
                try await emit(previous, at: previousTime)
                let count = options.motion.inBetween
                let phases = (1...count).map { Float($0) / Float(count + 1) }
                let destinations = try phases.map { _ in
                    VTFrameProcessorFrame(buffer: try makeBuffer(width, height, kCVPixelFormatType_64RGBAHalf), presentationTimeStamp: time)!
                }
                if let parameters = VTFrameRateConversionParameters(sourceFrame: previous, nextFrame: frame, opticalFlow: nil,
                                                                    interpolationPhase: phases, submissionMode: .sequential,
                                                                    destinationFrames: destinations) {
                    _ = try await interpolator.process(parameters: parameters)
                    for (phase, destination) in zip(phases, destinations) {
                        makeOpaque(destination.buffer)
                        try await emit(destination, at: previousTime + (seconds - previousTime) * Double(phase))
                    }
                }
            } else if interpolator == nil {
                try await emit(frame, at: seconds)
            }
            if interpolator != nil { pending = (frame, seconds) }
            progress(min(time.seconds - duration.start.seconds, total) / total)
        }
        if let (last, lastTime) = pending { try await emit(last, at: lastTime) }
        guard reader.status != .failed else { throw Enhance.Failure.writing(reader.error?.localizedDescription ?? "") }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, written > 0 else { throw Enhance.Failure.writing(writer.error?.localizedDescription ?? "") }
    }

    private func makeBuffer(_ width: Int, _ height: Int, _ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attributes, &buffer) == kCVReturnSuccess, let buffer else {
            throw Enhance.Failure.writing(String(localized: "There isn’t enough memory to process this video."))
        }
        return buffer
    }

    /// Apple's processors leave the alpha channel undefined, which Core Image would turn into a
    /// black picture: make every pixel opaque.
    private func makeOpaque(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // 1.0 as a 16-bit float, written as its bit pattern (Float16 itself isn't on Intel Macs).
        let one: UInt16 = 0x3C00
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt16.self) else { return }
        let rowLength = CVPixelBufferGetBytesPerRow(buffer) / 2
        let width = CVPixelBufferGetWidth(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let row = base + y * rowLength
            for x in 0..<width { row[x * 4 + 3] = one }
        }
    }
}

extension Enhance {
    /// A rough time on Apple silicon, from measured speeds: the 4× upscaler handles about 65
    /// million output pixels a second, adding frames about 20 million source pixels a second.
    static func estimatedSeconds(width: Int, height: Int, duration: Double, frameRate: Double, options: Options) -> Double {
        let sourcePixels = Double(max(width * height, 1))
        let outputFrames = duration * frameRate * Double(options.motion.inBetween + 1)
        var seconds = 0.0
        if options.upscale.height.map({ Double($0) > Double(min(width, height)) }) ?? false {
            seconds += outputFrames / (65_000_000 / (16 * sourcePixels))
        }
        if options.motion != .off { seconds += duration * frameRate / (20_000_000 / sourcePixels) }
        return seconds
    }
}

extension AIStudio {
    /// Makes an "(enhanced)" copy next to the video: upscaled and/or with frames added.
    func enhance(_ item: DownloadItem, options: Enhance.Options) {
        guard #available(macOS 26, *), Enhance.isSupported, let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            let picture = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-enhance-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: picture) }
            do {
                item.aiStatus = options.upscale != .off ? String(localized: "Upscaling…") : String(localized: "Adding frames…")
                item.aiProgress = 0
                let enhancer = VideoEnhancer(options: options)
                try await Task.detached(priority: .userInitiated) {
                    try await enhancer.run(input: file, output: picture) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    }
                }.value

                item.aiStatus = String(localized: "Saving…")
                item.aiProgress = nil
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (enhanced)"),
                                                  fileExtension: "mp4")
                // The original sound with the new picture; slow motion has no sound.
                var args = ["-y", "-v", "error", "-i", picture.path]
                if options.motion.stretch == 1 { args += ["-i", file.path, "-map", "0:v", "-map", "1:a?", "-c:a", "copy", "-shortest"] }
                else { args += ["-map", "0:v", "-an"] }
                args += ["-c:v", "copy", "-tag:v", "hvc1", "-map_metadata", "-1", "-movflags", "+faststart", output.path]
                try await ffmpeg(args, failure: Enhance.Failure.noVideo)
                finishJob(item)
                notify(title: String(localized: "“\(item.title)” is enhanced"),
                       body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }
}
