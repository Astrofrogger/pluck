import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import Vision

/// Steadies shaky footage, so it can be seen before exporting: how the camera shook is measured
/// frame to frame (Vision), the path is smoothed, and a steadied copy of the file is made once
/// (with its sound). Projects and the Editor play and export that copy.
@MainActor
@Observable
final class Stabilizer {
    static let shared = Stabilizer()

    /// Files being steadied, and how far (0…1).
    private(set) var working: [String: Double] = [:]
    private(set) var problems: [String: String] = [:]
    /// Counts finished copies, so views that show them update.
    private(set) var finished = 0

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Stabilized", isDirectory: true)
    }

    /// Where a file's steadied copy is kept (by the file and when it changed).
    nonisolated static func copyURL(for path: String) -> URL {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let name = SHA256.hash(data: Data("\(path)|\(modified)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + ".mov")
    }

    /// The steadied copy, once it's made.
    nonisolated static func copy(for path: String) -> URL? {
        let url = copyURL(for: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start(_ path: String) {
        guard working[path] == nil, Self.copy(for: path) == nil else { return }
        working[path] = 0
        problems[path] = nil
        Task {
            do {
                try await Self.make(path) { value in Task { @MainActor in self.working[path] = value } }
                finished += 1
            } catch {
                problems[path] = error.localizedDescription
            }
            working[path] = nil
        }
    }

    // MARK: - Measuring and making

    nonisolated private static func make(_ path: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Pluck", code: 20, userInfo: [NSLocalizedDescriptionKey: String(localized: "There's no picture to steady.")])
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let fps = Double(try await track.load(.nominalFrameRate))

        // 1. How the camera moved: each frame against the one before, small.
        let small = 480.0, scale = small / max(size.width, 1)
        var moves: [CGPoint] = [.zero]
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(small), kCVPixelBufferHeightKey as String: Int((size.height * scale).rounded()),
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            reader.startReading()
            var previous: CVPixelBuffer?
            var path = CGPoint.zero
            while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
                try Task.checkCancellation()
                if let previous {
                    let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
                    try? VNImageRequestHandler(cvPixelBuffer: previous).perform([request])
                    if let t = request.results?.first?.alignmentTransform {
                        path.x += t.tx
                        path.y += t.ty
                    }
                    moves.append(path)
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    progress(min(time / max(duration, 0.1), 1) * 0.4)
                }
                previous = buffer
            }
        }
        // 2. The path the camera should have taken (smoothed over about a second), and the
        //    correction to get there, full size.
        let sigma = max(fps * 0.6, 6)
        let radius = Int(sigma * 2.5)
        var corrections: [CGPoint] = []
        corrections.reserveCapacity(moves.count)
        for i in moves.indices {
            var sx = 0.0, sy = 0.0, weights = 0.0
            for j in max(0, i - radius)...min(moves.count - 1, i + radius) {
                let w = exp(-Double((j - i) * (j - i)) / (2 * sigma * sigma))
                sx += moves[j].x * w; sy += moves[j].y * w; weights += w
            }
            // Vision's shifts move each frame onto the one before: summed, they're the content's
            // drift the other way. The frame moves by the drift less its smoothed path.
            corrections.append(CGPoint(x: (moves[i].x - sx / weights) / scale, y: (moves[i].y - sy / weights) / scale))
        }
        let most = corrections.reduce(0.0) { max($0, abs($1.x) / size.width, abs($1.y) / size.height) }
        let zoom = min(1 + 2 * most + 0.01, 1.3)

        // 3. The steadied copy: each frame moved by its correction and zoomed just enough to hide
        //    the edges; the sound copied as it is.
        let target = copyURL(for: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = target.deletingPathExtension().appendingPathExtension("part.mov")
        try? FileManager.default.removeItem(at: partial)
        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(videoOut)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let audioOut = audioTrack.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        if let audioOut { reader.add(audioOut) }
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 0.85],
        ])
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if let audioTrack, let format = try await audioTrack.load(.formatDescriptions).first {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        let frame = CGRect(origin: .zero, size: size)
        var index = 0
        // Picture and sound in time order, each when its input is ready (the writer waits for
        // both to interleave them).
        var nextVideo = videoOut.copyNextSampleBuffer()
        var nextAudio = audioOut?.copyNextSampleBuffer()
        if nextVideo == nil { videoIn.markAsFinished() }
        if nextAudio == nil { audioIn?.markAsFinished() }
        while nextVideo != nil || nextAudio != nil {
            try Task.checkCancellation()
            let videoTime = nextVideo.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            let audioTime = nextAudio.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            let videoReady = nextVideo != nil && videoIn.isReadyForMoreMediaData
            let audioReady = nextAudio != nil && (audioIn?.isReadyForMoreMediaData ?? false)
            if videoReady && (videoTime <= audioTime || !audioReady), let sample = nextVideo {
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    let c = corrections[min(index, corrections.count - 1)]
                    // Vision's shift is in the picture's own pixels, y up as in Core Image.
                    let image = CIImage(cvPixelBuffer: buffer)
                        .transformed(by: CGAffineTransform(translationX: c.x, y: c.y))
                        .transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
                            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
                        .clampedToExtent().cropped(to: frame)
                    if let pool = adaptor.pixelBufferPool {
                        var out: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                        if let out {
                            context.render(image, to: out)
                            adaptor.append(out, withPresentationTime: time)
                        }
                    }
                    index += 1
                    progress(0.4 + min(time.seconds / max(duration, 0.1), 1) * 0.55)
                }
                nextVideo = videoOut.copyNextSampleBuffer()
                if nextVideo == nil { videoIn.markAsFinished() }
            } else if audioReady, let sample = nextAudio, let audioIn {
                audioIn.append(sample)
                nextAudio = audioOut?.copyNextSampleBuffer()
                if nextAudio == nil { audioIn.markAsFinished() }
            } else {
                try await Task.sleep(for: .milliseconds(3))
            }
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            throw writer.error ?? NSError(domain: "Pluck", code: 21)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        progress(1)
    }
}

/// Stabilize: steadies the file once (a minute or two for a few minutes of footage), then it's
/// used everywhere: the preview, the export.
struct StabilizeRow: View {
    let look: ClipLook
    let path: String?
    let change: (Bool, @escaping (inout ClipLook) -> Void) -> Void
    @State private var stabilizer = Stabilizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Stabilize").foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                Toggle("Stabilize", isOn: Binding(get: { look.stabilize }, set: { on in
                    change(true) { $0.stabilize = on }
                    if on, let path { stabilizer.start(path) }
                }))
                .toggleStyle(.switch).labelsHidden()
                Spacer()
            }
            if let path, look.stabilize {
                if let value = stabilizer.working[path] {
                    ProgressView(value: value).controlSize(.small)
                    Text("Steadying the footage…").font(.caption).foregroundStyle(.secondary)
                } else if let problem = stabilizer.problems[path] {
                    ProblemLabel(text: problem)
                } else if Stabilizer.copy(for: path) == nil {
                    Button("Steady It") { stabilizer.start(path) }.controlSize(.small)
                } else {
                    Label("Steadied: shown in the picture", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
    }
}
