import SwiftUI

/// The exports of one file in the Editor: how far the current one is, and what came out. Kept
/// with the file's model, so an export carries on while another tab or page is shown.
@MainActor
@Observable
final class EditorExports {
    /// How far the export is (0…1), while one runs.
    private(set) var progress: Double?
    /// The file the last export wrote.
    private(set) var output: URL?
    private(set) var problem: String?
    /// Handed to Pluck's conversions, which show in the download list.
    private(set) var handedOver = false
    /// Everything this file exported, newest first.
    private(set) var finished: [URL] = []

    var isRunning: Bool { progress != nil }

    func run(_ choice: EditorExportChoice, model: EditorModel, manager: DownloadManager) {
        output = nil
        problem = nil
        let parts = model.isEdited ? model.keptParts : [model.rangeStart...model.rangeEnd]
        switch choice.format {
        case .gif, .original:
            // GIFs and copies through Pluck's conversions, which show in the download list.
            let clips: [ClipRange?] = model.isEdited ? parts.map { ClipRange(start: $0.lowerBound, end: $0.upperBound) } : [model.clip]
            for clip in clips {
                let preset: Conversion.Preset = choice.format.preset == .trim && clip == nil ? .mp4 : choice.format.preset
                manager.convert([model.file], preset: preset, clip: clip)
            }
            if choice.srt { writeSRT(model, for: parts, next: nil) }
            withAnimation { handedOver = true }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation { handedOver = false }
            }
        case .video, .audio:
            let groups = choice.each && model.isEdited ? parts.map { [$0] } : [parts]
            render(groups, choice: choice, model: model, manager: manager)
        }
    }

    /// Each group of parts as one file, one after the other, next to the downloads.
    private func render(_ groups: [[ClosedRange<Double>]], choice: EditorExportChoice, model: EditorModel, manager: DownloadManager) {
        guard let ffmpeg = manager.tool("ffmpeg") else { problem = Converting.Failure.noFFmpeg.localizedDescription; return }
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let audioOnly = choice.format == .audio || !model.hasVideo
        let settings = choice.settings
        let base = model.file.deletingPathExtension().lastPathComponent
        let video = model.hasVideo, audio = model.hasAudio, file = model.file
        let source = model.pixelSize, fps = model.frameRate
        var pictureChain: ((String, Double, Double, Int) -> [String])?
        var steadied: URL?
        #if STUDIO
        if let look = model.look, !audioOnly {
            let width = Int(source.width) / 2 * 2, height = Int(source.height) / 2 * 2, rate = String(format: "%.3f", max(fps, 1))
            steadied = look.stabilize ? Stabilizer.copy(for: file.path) : nil
            let isSteadied = steadied != nil
            pictureChain = { input, start, end, k in
                ClipLook.ffmpegChain(input: input, start: start, end: end, length: end - start, look: look, k: k,
                                     width: width, height: height, rate: rate, steadied: isSteadied)
            }
        }
        #endif
        progress = 0
        Task {
            for (index, parts) in groups.enumerated() {
                let suffix = groups.count > 1 ? String(localized: " (part \(index + 1))")
                    : model.isEdited ? String(localized: " (edit)") : model.hasRange ? String(localized: " (part)") : String(localized: " (export)")
                let output = Converting.outputURL(folder: folder, name: base + suffix,
                                                  fileExtension: audioOnly ? settings.audioFile.rawValue : settings.container.fileExtension)
                var assFile: URL?
                if choice.burn, !audioOnly {
                    let ass = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-editor-\(UUID().uuidString).ass")
                    let text = EditorSubtitleFiles.ass(model.subtitlesForEdit(parts), style: model.subtitleStyle,
                                                       width: Int(source.width), height: Int(source.height))
                    if (try? text.write(to: ass, atomically: true, encoding: .utf8)) != nil { assFile = ass }
                }
                let count = Double(groups.count)
                let done = await EditorExport.joined(parts, of: file, video: video, audio: audio, to: output, ffmpeg: ffmpeg,
                                                     settings: settings, audioOnly: audioOnly, source: source, sourceFPS: fps,
                                                     subtitles: assFile, pictureChain: pictureChain, steadied: steadied) { value in
                    Task { @MainActor in self.progress = (Double(index) + value) / count }
                }
                if let assFile { try? FileManager.default.removeItem(at: assFile) }
                if done {
                    self.output = output
                    finished.insert(output, at: 0)
                    if choice.srt { writeSRT(model, for: parts, next: output) }
                    _ = manager.addLocalFiles([output])
                } else {
                    try? FileManager.default.removeItem(at: output)
                    problem = String(localized: "The export couldn’t be written.")
                    break
                }
            }
            progress = nil
            manager.saveHistory()
        }
    }

    /// The subtitles for what's exported as an .srt file: next to the exported file, or in the
    /// downloads folder.
    private func writeSRT(_ model: EditorModel, for parts: [ClosedRange<Double>], next output: URL?) {
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        let url = output?.deletingPathExtension().appendingPathExtension("srt")
            ?? Converting.outputURL(folder: folder, name: model.file.deletingPathExtension().lastPathComponent, fileExtension: "srt")
        try? EditorSubtitleFiles.srt(model.subtitlesForEdit(parts)).write(to: url, atomically: true, encoding: .utf8)
    }
}
