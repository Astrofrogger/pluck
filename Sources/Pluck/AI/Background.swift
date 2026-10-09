import AppKit
import CoreImage
import Vision

/// New Background: Apple's person cutout (Vision, local AI) separates people from what's behind
/// them, frame by frame, without a green screen. The background is blurred, replaced by a colour
/// or picture, or made transparent for editing.
enum Background {
    enum Kind: String, CaseIterable, Identifiable {
        case blur, color, image, transparent
        var id: String { rawValue }

        var label: String {
            switch self {
            case .blur: String(localized: "Blur")
            case .color: String(localized: "Colour")
            case .image: String(localized: "Picture")
            case .transparent: String(localized: "Transparent")
            }
        }

        var detail: String {
            switch self {
            case .blur: String(localized: "Keeps the room but softly out of focus, like a portrait lens.")
            case .color: String(localized: "A plain colour behind the people.")
            case .image: String(localized: "A photo of your choice behind the people.")
            case .transparent: String(localized: "No background at all: a ProRes 4444 file to place over other footage in your editor.")
            }
        }
    }

    struct Options {
        var kind: Kind = .blur
        /// RGB hex without "#", for `.color`.
        var color = "1C1C1E"
        /// The picture for `.image`.
        var image: URL?
    }

    static let swatches = ["1C1C1E", "FFFFFF", "0A84FF", "30D158", "FF5C6B"]

    /// The step that gives one frame its new background.
    final class Painter: @unchecked Sendable {
        private let options: Options
        private let request = VNGeneratePersonSegmentationRequest()
        private let sequence = VNSequenceRequestHandler()
        private var picture: CIImage?

        init(options: Options) {
            self.options = options
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            if options.kind == .image, let url = options.image { picture = CIImage(contentsOf: url) }
        }

        func paint(_ frame: CIImage) throws -> CIImage {
            let extent = frame.extent
            try sequence.perform([request], on: frame)
            guard let maskBuffer = request.results?.first?.pixelBuffer else { return frame }
            var mask = CIImage(cvPixelBuffer: maskBuffer)
            mask = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            // A slightly soft edge reads as natural hair and shoulders, not a cut-out.
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: max(extent.height / 900, 1)).cropped(to: extent)

            let background: CIImage
            switch options.kind {
            case .blur:
                background = frame.clampedToExtent().applyingGaussianBlur(sigma: extent.height / 45).cropped(to: extent)
            case .color:
                let (r, g, b) = Background.rgb(options.color)
                background = CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: extent)
            case .image:
                guard let picture else { return frame }
                // Fill the frame, cropping the picture's overflow evenly.
                let scale = max(extent.width / picture.extent.width, extent.height / picture.extent.height)
                let scaled = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                background = scaled.transformed(by: CGAffineTransform(translationX: (extent.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                      y: (extent.height - scaled.extent.height) / 2 - scaled.extent.minY))
                    .cropped(to: extent)
            case .transparent:
                background = CIImage(color: .clear).cropped(to: extent)
            }
            return frame.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask])
        }
    }

    static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat) {
        let value = Int(hex, radix: 16) ?? 0
        return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }
}

extension AIStudio {
    /// Makes a "(new background)" copy next to the video.
    func replaceBackground(_ item: DownloadItem, options: Background.Options) {
        guard let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Finding the people…")
            item.aiProgress = 0
            let transparent = options.kind == .transparent
            let picture = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-background-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: picture) }
            do {
                let painter = Background.Painter(options: options)
                try await Task.detached(priority: .userInitiated) {
                    try await FrameRewriter().run(input: file, output: picture, codec: transparent ? .proRes4444 : .hevc) { progress in
                        Task { @MainActor in item.aiProgress = progress }
                    } edit: { frame in
                        try painter.paint(frame.image)
                    }
                }.value

                item.aiStatus = String(localized: "Saving…")
                item.aiProgress = nil
                let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (new background)"),
                                                  fileExtension: transparent ? "mov" : "mp4")
                var args = ["-y", "-v", "error", "-i", picture.path, "-i", file.path, "-map", "0:v", "-map", "1:a?",
                            "-c:v", "copy", "-shortest"]
                args += transparent ? ["-c:a", "pcm_s16le"] : ["-c:a", "copy", "-tag:v", "hvc1", "-movflags", "+faststart"]
                try await ffmpeg(args + [output.path], failure: FrameRewriter.Failure.noVideo)
                finishJob(item)
                notify(title: String(localized: "“\(item.title)” has a new background"),
                       body: String(localized: "Saved as “\(output.lastPathComponent)”."), files: [output])
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                failJob(item, error)
            }
        }
    }
}
