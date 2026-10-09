import AppKit
import Foundation

extension AIStudio {
    /// Makes vertical shorts from a video into a "(shorts)" folder next to it.
    func makeShorts(_ item: DownloadItem, options: Shorts.Options) {
        guard #available(macOS 26, *), let file = item.existingFile, item.aiStatus == nil else { return }
        item.aiStatus = String(localized: "Preparing…")
        item.aiProgress = nil
        Task {
            do {
                let transcript = try await existingOrNewTranscript(for: item, file: file)
                item.aiStatus = String(localized: "Choosing the best moments…")
                item.aiProgress = nil
                let moments = await Shorts.moments(in: transcript, options: options)
                guard !moments.isEmpty else { throw LocalAI.Failure.noSpeech }
                guard let size = await videoSize(file) else { throw Converting.Failure.noVideo }

                let folder = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (shorts)"),
                                                  fileExtension: "").deletingPathExtension()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, moment) in moments.enumerated() {
                    item.aiStatus = String(localized: "Making short \(index + 1) of \(moments.count)…")
                    item.aiProgress = 0
                    try await renderShort(moment, number: index + 1, from: file, size: size, transcript: transcript,
                                          options: options, into: folder, item: item)
                }
                item.aiStatus = nil
                item.aiProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                item.aiStatus = nil
                item.aiProgress = nil
                let alert = NSAlert()
                alert.messageText = String(localized: "Shorts couldn’t be made from “\(item.title)”")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @available(macOS 26, *)
    private func renderShort(_ moment: Shorts.Moment, number: Int, from file: URL, size: (Int, Int), transcript: Transcript,
                             options: Shorts.Options, into folder: URL, item: DownloadItem) async throws {
        let (width, height) = size
        let duration = moment.end - moment.start
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-short-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Landscape: a 9:16 window that follows the subject. Already vertical: just scale.
        let cropFraction = (Double(height) * 9 / 16).rounded(.down) / Double(width)
        let path = options.followSubject && cropFraction < 0.95
            ? await Shorts.track(file, from: moment.start, to: moment.end, cropWidth: cropFraction) : nil
        var captions: URL?
        if options.captions != .none {
            captions = work.appendingPathComponent("captions.ass")
            try Shorts.captionFile(for: moment, transcript: transcript, style: options.captions, to: captions!)
        }
        let filters = try Shorts.filters(sourceWidth: width, sourceHeight: height, path: path,
                                         commandFile: work.appendingPathComponent("reframe.txt"), captions: captions)

        let name = "\(number) - \(Folders.sanitize(moment.title))"
        let output = Converting.outputURL(folder: folder.path, name: name, fileExtension: "mp4")
        try await ffmpeg(["-y", "-v", "error", "-progress", "pipe:1", "-nostats",
                          "-ss", String(moment.start), "-t", String(duration), "-i", file.path,
                          "-vf", filters.joined(separator: ","),
                          "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", "30",
                          "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path],
                         failure: Converting.Failure.noVideo, duration: duration, item: item)
    }
}
