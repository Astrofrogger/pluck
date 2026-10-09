import AVFoundation
import CoreImage

/// Rewrites every frame of a video through a Core Image step, for the picture features that work
/// frame by frame (new background, privacy blur). Frames are handed over upright (phone videos
/// included), so Vision sees faces and people the right way round, and are written upright.
/// Colours pass through untouched and the output is tagged BT.709, like Upscale & Smooth.
final class FrameRewriter: @unchecked Sendable {
    enum Codec {
        /// HEVC in a .mov/.mp4, for normal use.
        case hevc
        /// ProRes 4444 with an alpha channel, for a transparent background.
        case proRes4444
    }

    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    struct Frame {
        /// The picture, upright, with its origin at (0, 0).
        let image: CIImage
        let seconds: Double
    }

    /// Reads `input`, sends each frame through `edit`, writes the picture (no sound) to `output`.
    func run(input: URL, output: URL, codec: Codec, progress: @escaping @Sendable (Double) -> Void,
             edit: (Frame) async throws -> CIImage) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform, rate, range) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: (abs(upright.width) / 2).rounded() * 2, height: (abs(upright.height) / 2).rounded() * 2)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let frameRate = Double(rate > 0 ? rate : 30)
        let color: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        var settings: [String: Any] = [AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height), AVVideoColorPropertiesKey: color]
        switch codec {
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevc
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(min(max(size.width * size.height * frameRate * 0.12, 4_000_000), 60_000_000)),
                AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
            ]
        case .proRes4444:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(writerInput)
        guard reader.startReading(), writer.startWriting() else {
            throw Failure.writing(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let total = max(range.duration.seconds, 0.1)
        let orientation = Self.orientation(of: transform)
        var written = 0
        while let sample = readerOutput.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) {
            try Task.checkCancellation()
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let seconds = time.seconds - range.start.seconds
            var image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let edited = try await edit(Frame(image: image, seconds: seconds)).cropped(to: CGRect(origin: .zero, size: size))

            guard let pool = adaptor.pixelBufferPool else { throw Failure.writing(writer.error?.localizedDescription ?? "") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw Failure.writing(String(localized: "There isn’t enough memory to process this video.")) }
            context.render(edited, to: buffer)
            while !writerInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) else {
                throw Failure.writing(writer.error?.localizedDescription ?? "")
            }
            written += 1
            progress(min(seconds / total, 1))
        }
        guard reader.status != .failed else { throw Failure.writing(reader.error?.localizedDescription ?? "") }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, written > 0 else { throw Failure.writing(writer.error?.localizedDescription ?? "") }
    }

    /// The rotation a phone video is stored with, as an image orientation.
    static func orientation(of transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a, transform.b, transform.c, transform.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        default: .up
        }
    }

    enum Failure: LocalizedError {
        case noVideo, writing(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "Pluck couldn’t read the picture of this video.")
            case .writing(let reason): reason.isEmpty ? String(localized: "Pluck couldn’t save the video.") : reason
            }
        }
    }
}
